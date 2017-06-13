# frozen_string_literal: true
module KubernetesDeploy
  class ReplicaSet < KubernetesResource
    TIMEOUT = 5.minutes

    def initialize(name:, namespace:, context:, file:, parent: nil, logger:)
      @name = name
      @namespace = namespace
      @context = context
      @file = file
      @parent = parent
      @logger = logger
      @pods = []
      @rollout_data = { "replicas" => 0 }
    end

    def sync
      raw_json, _err, st = kubectl.run("get", type, @name, "--output=json")

      if @found = st.success?
        rs_data = JSON.parse(raw_json)
        interpret_json_data(rs_data)
      else # reset
        @rollout_data = { "replicas" => 0 }
        @status = nil
        @pods = []
      end
    end

    def interpret_json_data(rs_data)
      pods_data = get_pods(rs_data)

      pods_data.each do |pod_data|
        pod = Pod.new(
          name: pod_data["metadata"]["name"],
          namespace: namespace,
          context: context,
          file: nil,
          parent: "#{@name.capitalize} replica set",
          logger: @logger
        )
        pod.deploy_started = @deploy_started
        pod.interpret_json_data(pod_data)
        @pods << pod
      end

      @rollout_data.merge!(rs_data["status"]
        .slice("replicas", "availableReplicas", "readyReplicas"))
      @status = @rollout_data.map { |st, num| "#{num} #{st.chop.pluralize(num)}" }.join(", ")
    end

    def deploy_succeeded?
      @rollout_data["replicas"].to_i == @rollout_data["availableReplicas"].to_i &&
      @rollout_data["replicas"].to_i == @rollout_data["readyReplicas"].to_i
    end

    def deploy_failed?
      @pods.present? && @pods.all?(&:deploy_failed?)
    end

    def deploy_timed_out?
      super || @pods.present? && @pods.all?(&:deploy_timed_out?)
    end

    def exists?
      unmanaged? ? @found : true
    end

    def fetch_events
      own_events = super
      return own_events unless @pods.present?
      own_events.merge(@pods.first.fetch_events)
    end

    def fetch_logs
      container_names.each_with_object({}) do |container_name, container_logs|
        out, _err, _st = kubectl.run(
          "logs",
          id,
          "--container=#{container_name}",
          "--since-time=#{@deploy_started.to_datetime.rfc3339}",
          "--tail=#{LOG_LINE_COUNT}"
        )
        container_logs["#{id}/#{container_name}"] = out
      end
    end

    private

    def unmanaged?
      @parent.blank?
    end

    def container_names
      return [] unless template
      template["spec"]["template"]["spec"]["containers"].map { |c| c["name"] }
    end

    def get_pods(rs_data)
      label_string = rs_data["spec"]["selector"]["matchLabels"].map { |k, v| "#{k}=#{v}" }.join(",")
      raw_json, _err, st = kubectl.run("get", "pods", "-a", "--output=json", "--selector=#{label_string}")
      return [] unless st.success?

      all_pods = JSON.parse(raw_json)["items"]
      all_pods.each_with_object([]) do |pod, relevant_pods|
        next unless pod["metadata"]["ownerReferences"].any? { |ref| ref["uid"] == rs_data["metadata"]["uid"] }
        relevant_pods << pod
      end
    end
  end
end
