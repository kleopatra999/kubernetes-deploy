# frozen_string_literal: true
module KubernetesDeploy
  class ReplicaSet < KubernetesResource
    TIMEOUT = 5.minutes
    attr_reader :pods

    def initialize(name:, namespace:, context:, file:, parent: nil, logger:)
      @name = name
      @namespace = namespace
      @context = context
      @file = file
      @parent = parent
      @logger = logger
      @pods = []
    end

    def sync
      out, _err, st = kubectl.run("get", type, @name, "--output=json")
      @found = st.success?
      @rollout_data = {}
      @status = nil
      @pods = []

      if @found
        rs_data = JSON.parse(out)
        interpret_json_data(rs_data)
      end
    end

    def exists?
      @found
    end

    def interpret_json_data(rs_data)
      pods_data = get_pods(rs_data)

      pods_data.each do |pod_data|
        pod = Pod.new(
          name: pod_data["metadata"]["name"],
          namespace: namespace,
          context: context,
          file: nil,
          parent: "#{@name.capitalize} replicaSet",
          logger: @logger
        )
        pod.deploy_started = @deploy_started
        pod.interpret_json_data(pod_data)
        @pods << pod
      end

      @rollout_data = compose_rollout_data(rs_data["status"], @pods.length)
      @status = @rollout_data.map { |st, num| "#{num} #{st}" }.join(", ")
    end

    def get_logs
      return {} unless @pods.present?
      @pods.first.get_logs
    end

    private

    def get_pods(rs_data)
      label_string = rs_data["spec"]["selector"]["matchLabels"].map { |k,v| "#{k}=#{v}" }.join(",")
      raw_json, _err, st = kubectl.run("get", "pods", "-a", "--output=json", "--selector=#{label_string}")
      return [] unless st.success?

      all_pods = JSON.parse(raw_json)["items"]
      all_pods.each_with_object([]) do |pod, relevant_pods|
        next unless pod["metadata"]["ownerReferences"].any? { |ref| ref["uid"] == rs_data["metadata"]["uid"] }
        relevant_pods << pod
      end
    end

    def compose_rollout_data(status_data, observed_pod_count)
      rollout_data = { "updatedReplicasObserved" => observed_pod_count }
      %w(updatedReplicas replicas availableReplicas unavailableReplicas).each do |replica_group|
        rollout_data[replica_group] = status_data.fetch(replica_group, 0)
      end
      rollout_data
    end
  end
end
