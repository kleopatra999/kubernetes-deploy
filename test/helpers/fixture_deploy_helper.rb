# frozen_string_literal: true
require 'securerandom'
module FixtureDeployHelper
  EJSON_FILENAME = KubernetesDeploy::EjsonSecretProvisioner::EJSON_SECRETS_FILE

  # Deploys the specified set of fixtures via KubernetesDeploy::Runner.
  #
  # Optionally takes an array of filenames belonging to the fixture, and deploys that subset only.
  # Example:
  # # Deploys hello-cloud/redis.yml
  # deploy_fixtures("hello-cloud", ["redis.yml"])
  #
  # Optionally yields a hash of the fixture's loaded templates that can be modified before the deploy is executed.
  # The following example illustrates the format of the yielded hash:
  #  {
  #    "web.yml.erb" => {
  #      "Ingress" => [loaded_ingress_yaml],
  #      "Service" => [loaded_service_yaml],
  #      "Deployment" => [loaded_service_yaml]
  #    }
  #  }
  #
  # Example:
  # # The following will deploy the "hello-cloud" fixture set, but with the unmanaged pod modified to use a bad image
  #   deploy_fixtures("hello-cloud") do |fixtures|
  #     pod = fixtures["unmanaged-pod.yml.erb"]["Pod"].first
  #     pod["spec"]["containers"].first["image"] = "hello-world:thisImageIsBad"
  #   end
  def deploy_fixtures(set, subset: nil, wait: true, allow_protected_ns: false, prune: true, bindings: {})
    fixtures = load_fixtures(set, subset)
    raise "Cannot deploy empty template set" if fixtures.empty?

    yield fixtures if block_given?

    success = false
    Dir.mktmpdir("fixture_dir") do |target_dir|
      write_fixtures_to_dir(fixtures, target_dir)
      success = deploy_dir(target_dir, wait: wait, allow_protected_ns: allow_protected_ns,
        prune: prune, bindings: bindings)
    end
    success
  end

  def deploy_raw_fixtures(set, wait: true, bindings: {})
    deploy_dir(fixture_path(set), wait: wait, bindings: bindings)
  end

  # Deploys all fixtures in the given directory via KubernetesDeploy::Runner
  # Exposed for direct use only when deploy_fixtures cannot be used because the template cannot be loaded pre-deploy,
  # for example because it contains an intentional syntax error
  def deploy_dir(dir, wait: true, allow_protected_ns: false, prune: true, bindings: {})
    runner = KubernetesDeploy::Runner.new(
      namespace: @namespace,
      current_sha: SecureRandom.hex(6),
      context: KubeclientHelper::MINIKUBE_CONTEXT,
      template_dir: dir,
      logger: logger,
      bindings: bindings
    )
    runner.run(
      verify_result: wait,
      allow_protected_ns: allow_protected_ns,
      prune: prune
    )
  end

  private

  def load_fixtures(set, subset)
    fixtures = {}
    ejson_file = File.join(fixture_path(set), EJSON_FILENAME)
    fixtures[EJSON_FILENAME] = JSON.parse(File.read(ejson_file)) if File.exist?(ejson_file)

    Dir["#{fixture_path(set)}/*.yml*"].each do |filename|
      basename = File.basename(filename)
      next unless !subset || subset.include?(basename)

      content = File.read(filename)
      fixtures[basename] = {}
      YAML.load_stream(content) do |doc|
        fixtures[basename][doc["kind"]] ||= []
        fixtures[basename][doc["kind"]] << doc
      end
    end
    fixtures
  end

  def write_fixtures_to_dir(fixtures, target_dir)
    fixtures.each do |filename, file_data|
      data_str = filename == EJSON_FILENAME ? file_data.to_json : YAML.dump_stream(*file_data.values.flatten)
      File.write(File.join(target_dir, filename), data_str)
    end
  end
end
