# frozen_string_literal: true
require 'open3'
require 'securerandom'
require 'erb'
require 'yaml'
require 'shellwords'
require 'tempfile'
require 'kubernetes-deploy/kubernetes_resource'
%w(
  cloudsql
  config_map
  deployment
  ingress
  persistent_volume_claim
  pod
  redis
  service
  pod_template
  bugsnag
  pod_disruption_budget
).each do |subresource|
  require "kubernetes-deploy/kubernetes_resource/#{subresource}"
end
require 'kubernetes-deploy/resource_watcher'
require "kubernetes-deploy/ui_helpers"
require 'kubernetes-deploy/kubectl'
require 'kubernetes-deploy/kubeclient_builder'
require 'kubernetes-deploy/ejson_secret_provisioner'

module KubernetesDeploy
  class Runner
    include UIHelpers
    include KubeclientBuilder

    PREDEPLOY_SEQUENCE = %w(
      Cloudsql
      Redis
      Bugsnag
      ConfigMap
      PersistentVolumeClaim
      Pod
    )
    PROTECTED_NAMESPACES = %w(
      default
      kube-system
      kube-public
    )

    # Things removed from default prune whitelist:
    # core/v1/Namespace -- not namespaced
    # core/v1/PersistentVolume -- not namespaced
    # core/v1/Endpoints -- managed by services
    # core/v1/PersistentVolumeClaim -- would delete data
    # core/v1/ReplicationController -- superseded by deployments/replicasets
    # extensions/v1beta1/ReplicaSet -- managed by deployments
    # core/v1/Secret -- should not committed / managed by shipit
    BASE_PRUNE_WHITELIST = %w(
      core/v1/ConfigMap
      core/v1/Pod
      core/v1/Service
      batch/v1/Job
      extensions/v1beta1/DaemonSet
      extensions/v1beta1/Deployment
      extensions/v1beta1/Ingress
      apps/v1beta1/StatefulSet
    ).freeze

    PRUNE_WHITELIST_V_1_5 = %w(extensions/v1beta1/HorizontalPodAutoscaler).freeze
    PRUNE_WHITELIST_V_1_6 = %w(autoscaling/v1/HorizontalPodAutoscaler).freeze

    def initialize(namespace:, context:, current_sha:, template_dir:, logger:, bindings: {})
      @namespace = namespace
      @context = context
      @current_sha = current_sha
      @template_dir = File.expand_path(template_dir)
      @logger = logger
      @bindings = bindings
      # Max length of podname is only 63chars so try to save some room by truncating sha to 8 chars
      @id = current_sha[0...8] + "-#{SecureRandom.hex(4)}" if current_sha
    end

    def run(verify_result: true, allow_protected_ns: false, prune: true)
      @started_at = Time.now.utc
      phase_heading("Initializing deploy")
      validate_configuration(allow_protected_ns: allow_protected_ns, prune: prune)
      confirm_context_exists
      confirm_namespace_exists
      resources = discover_resources

      phase_heading("Checking initial resource statuses")
      resources.each(&:sync)
      resources.each { |r| @logger.info(r.pretty_status) }

      ejson = EjsonSecretProvisioner.new(
        namespace: @namespace,
        context: @context,
        template_dir: @template_dir,
        logger: @logger
      )
      if ejson.secret_changes_required?
        phase_heading("Deploying kubernetes secrets from #{EjsonSecretProvisioner::EJSON_SECRETS_FILE}")
        ejson.run
      end

      if deploy_has_priority_resources?(resources)
        phase_heading("Predeploying priority resources")
        predeploy_priority_resources(resources)
      end

      phase_heading("Deploying all resources")
      if PROTECTED_NAMESPACES.include?(@namespace) && prune
        raise FatalDeploymentError, "Refusing to deploy to protected namespace '#{@namespace}' with pruning enabled"
      end

      deploy_resources(resources, prune: prune)

      return true unless verify_result
      wait_for_completion(resources)

      raise_resource_deploy_error(resources) unless resources.all?(&:deploy_succeeded?)
      report_deploy_success(resources)
      true
    rescue FatalDeploymentError => error
      report_deploy_failure(error.message.to_s, error.debug_info)
      false
    end

    def template_variables
      {
        'current_sha' => @current_sha,
        'deployment_id' => @id,
      }.merge(@bindings)
    end

    private

    def versioned_prune_whitelist
      if server_major_version == "1.5"
        BASE_PRUNE_WHITELIST + PRUNE_WHITELIST_V_1_5
      else
        BASE_PRUNE_WHITELIST + PRUNE_WHITELIST_V_1_6
      end
    end

    def server_major_version
      @server_major_version ||= begin
        out, _, _ = kubectl.run('version', '--short')
        matchdata = /Server Version: v(?<version>\d\.\d)/.match(out)
        raise "Could not determine server version" unless matchdata[:version]
        matchdata[:version]
      end
    end

    # Inspect the file referenced in the kubectl stderr
    # to make it easier for developer to understand what's going on
    def find_bad_file_from_kubectl_output(stderr)
      # Output example:
      # Error from server (BadRequest): error when creating "/path/to/configmap-gqq5oh.yml20170411-33615-t0t3m":
      match = stderr.match(%r{BadRequest.*"(?<path>\/\S+\.yml\S+)"})
      return unless match

      path = match[:path]
      if path.present? && File.file?(path)
        suspicious_file = File.read(path)
      end
      [File.basename(path, ".*"), suspicious_file]
    end

    def deploy_has_priority_resources?(resources)
      resources.any? { |r| PREDEPLOY_SEQUENCE.include?(r.type) }
    end

    def predeploy_priority_resources(resource_list)
      PREDEPLOY_SEQUENCE.each do |resource_type|
        matching_resources = resource_list.select { |r| r.type == resource_type }
        next if matching_resources.empty?
        deploy_resources(matching_resources)
        wait_for_completion(matching_resources)

        raise_resource_deploy_error(matching_resources, priority: true) unless matching_resources.all?(&:deploy_succeeded?)
        @logger.blank_line
      end
    end

    def discover_resources
      resources = []
      @logger.info("Discovering templates:")
      Dir.foreach(@template_dir) do |filename|
        next unless filename.end_with?(".yml.erb", ".yml")

        split_templates(filename) do |tempfile|
          resource_id = discover_resource_via_dry_run(tempfile)
          type, name = resource_id.split("/", 2) # e.g. "pod/web-198612918-dzvfb"
          resources << KubernetesResource.for_type(type: type, name: name, namespace: @namespace, context: @context,
            file: tempfile, logger: @logger)
           @logger.info "  - #{resource_id}"
        end
      end
      resources
    end

    def discover_resource_via_dry_run(tempfile)
      command = ["create", "-f", tempfile.path, "--dry-run", "--output=name"]
      resource_id, err, st = kubectl.run(*command, log_failure: false)

      unless st.success?
        deploy_err = FatalDeploymentError.new("Kubectl dry run failed (command: #{Shellwords.join(command)})")
        debug_msg = <<-DEBUG_MSG.strip_heredoc
        This means the template named '#{File.basename(tempfile.path, ".*")}' is not a valid Kubernetes template.

        Error from kubectl:
          #{err}

        Rendered template content:
        DEBUG_MSG
        debug_msg += File.read(tempfile.path)
        deploy_err.add_debug_info(debug_msg)
        raise deploy_err
      end
      resource_id
    end

    def split_templates(filename)
      file_content = File.read(File.join(@template_dir, filename))
      rendered_content = render_template(filename, file_content)
      YAML.load_stream(rendered_content) do |doc|
        next if doc.blank?

        f = Tempfile.new(filename)
        f.write(YAML.dump(doc))
        f.close
        yield f
      end
    rescue Psych::SyntaxError => e
      deploy_err = FatalDeploymentError.new("Template '#{filename}' cannot be parsed")
      debug_msg = <<-INFO.strip_heredoc
      Error message: #{e}

      Template content:
      ---
      INFO
      debug_msg << rendered_content
      deploy_err.add_debug_info(debug_msg)
      raise deploy_err
    end

    def raise_resource_deploy_error(resources, priority: false)
      fail_list = resources.select { |r| r.deploy_failed? || r.deploy_timed_out? }
      error = FatalDeploymentError.new("Failed to deploy #{fail_list.length} #{'priority ' if priority}resources")
      fail_list.each do |r|
        error.add_debug_info(r.debug_message)
      end

      raise error
    end

    def raise_apply_failure(command, err)
      deploy_err = FatalDeploymentError.new("Command failed: #{Shellwords.join(command)}")

      file_name, file_content = find_bad_file_from_kubectl_output(err)
      if file_name
        debug_msg = <<-HELPFUL_MESSAGE.strip_heredoc
        This means your template named '#{file_name}' is invalid.

        Error from kubectl:
          #{err}

        Rendered template content:
        HELPFUL_MESSAGE
        debug_msg += file_content || "Failed to read file"
      else
        debug_msg = <<-FALLBACK_MSG
        This means one of your templates is probably invalid, but we were unable to automatically identify each one.
        Please inspect the error message from kubectl:
          #{err}"
        FALLBACK_MSG
      end

      deploy_err.add_debug_info(debug_msg)
      raise deploy_err
    end

    def wait_for_completion(watched_resources)
      watcher = ResourceWatcher.new(watched_resources, logger: @logger)
      watcher.run
    end

    def render_template(filename, raw_template)
      return raw_template unless File.extname(filename) == ".erb"

      erb_template = ERB.new(raw_template)
      erb_binding = binding
      template_variables.each do |var_name, value|
        erb_binding.local_variable_set(var_name, value)
      end
      erb_template.result(erb_binding)
    rescue NameError => e
      deploy_err = FatalDeploymentError.new("Template '#{filename}' cannot be rendered")
      deploy_err.add_debug_info("Error from renderer:\n  #{e.message.gsub("\n", ' ')}")
      raise deploy_err
    end

    def validate_configuration(allow_protected_ns:, prune:)
      errors = []
      if ENV["KUBECONFIG"].blank? || !File.file?(ENV["KUBECONFIG"])
        errors << "Kube config not found at #{ENV['KUBECONFIG']}"
      end

      if @current_sha.blank?
        errors << "Current SHA must be specified"
      end

      if !File.directory?(@template_dir)
        errors << "Template directory `#{@template_dir}` doesn't exist"
      elsif Dir.entries(@template_dir).none? { |file| file =~ /\.yml(\.erb)?$/ }
        errors << "`#{@template_dir}` doesn't contain valid templates (postfix .yml or .yml.erb)"
      end

      if @namespace.blank?
        errors << "Namespace must be specified"
      elsif PROTECTED_NAMESPACES.include?(@namespace)
        if allow_protected_ns && prune
          errors << "Refusing to deploy to protected namespace '#{@namespace}' with pruning enabled"
        elsif allow_protected_ns
          @logger.warn("You're deploying to protected namespace #{@namespace}, which cannot be pruned.")
          @logger.warn("Existing resources can only be removed manually with kubectl. Removing templates from the set deployed will have no effect.")
          @logger.warn("***Please do not deploy to #{@namespace} unless you really know what you are doing.***")
        else
          errors << "Refusing to deploy to protected namespace '#{@namespace}'"
        end
      end

      if @context.blank?
        errors << "Context must be specified"
      end

      unless errors.empty?
        deploy_err = FatalDeploymentError.new("Configuration invalid")
        deploy_err.add_debug_info(errors.map { |err| "- #{err}" }.join("\n"))
        raise deploy_err
      end

      @logger.info("All required parameters and files are present")
    end

    def deploy_resources(resources, prune: false)
      @logger.info("Deploying resources:")

      # Apply can be done in one large batch, the rest have to be done individually
      applyables, individuals = resources.partition { |r| r.deploy_method == :apply }

      individuals.each do |r|
        @logger.info("- #{r.id}")
        r.deploy_started = Time.now.utc
        case r.deploy_method
        when :replace
          _, _, st = kubectl.run("replace", "-f", r.file.path, log_failure: false)
        when :replace_force
          _, _, st = kubectl.run("replace", "--force", "-f", r.file.path, log_failure: false)
        else
          # Fail Fast! This is a programmer mistake.
          raise ArgumentError, "Unexpected deploy method! (#{r.deploy_method.inspect})"
        end

        next if st.success?
        # it doesn't exist so we can't replace it
        _, err, st = kubectl.run("create", "-f", r.file.path, log_failure: false)
        unless st.success?
          raise FatalDeploymentError, <<-MSG.strip_heredoc
            Failed to replace or create resource: #{r.id}
            #{err}
          MSG
        end
      end

      apply_all(applyables, prune)
    end

    def apply_all(resources, prune)
      return unless resources.present?

      command = ["apply"]
      resources.each do |r|
        @logger.info("- #{r.id} (timeout: #{r.timeout}s)")
        command.push("-f", r.file.path)
        r.deploy_started = Time.now.utc
      end

      if prune
        command.push("--prune", "--all")
        versioned_prune_whitelist.each { |type| command.push("--prune-whitelist=#{type}") }
      end

      _, err, st = kubectl.run(*command, log_failure: false)
      unless st.success?
        raise_apply_failure(command, err)
      end
    end

    def confirm_context_exists
      out, err, st = kubectl.run("config", "get-contexts", "-o", "name", use_namespace: false, use_context: false, log_failure: false)
      available_contexts = out.split("\n")
      if !st.success?
        raise FatalDeploymentError, err
      elsif !available_contexts.include?(@context)
        raise FatalDeploymentError, "Context #{@context} is not available. Valid contexts: #{available_contexts}"
      end
      @logger.info("Context #{@context} found")
    end

    def confirm_namespace_exists
      _, _, st = kubectl.run("get", "namespace", @namespace, use_namespace: false, log_failure: false)
      raise FatalDeploymentError, "Namespace #{@namespace} not found" unless st.success?
      @logger.info("Namespace #{@namespace} found")
    end

    def kubectl
      @kubectl ||= Kubectl.new(namespace: @namespace, context: @context, logger: @logger, log_failure_by_default: true)
    end
  end
end
