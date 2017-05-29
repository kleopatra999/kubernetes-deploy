# frozen_string_literal: true
module KubernetesDeploy
  class Deployment < KubernetesResource
    TIMEOUT = 5.minutes

    def sync
      raw_json, _err, st = kubectl.run("get", type, @name, "--output=json")
      @found = st.success?
      @rollout_data = {}
      @status = nil
      @latest_rs_pods = []

      if @found
        deployment_data = JSON.parse(raw_json)
        latest_rs_data = get_latest_rs(deployment_data)
        @latest_rs = ReplicaSet.new(
          name: latest_rs_data["metadata"]["name"],
          namespace: namespace,
          context: context,
          file: nil,
          parent: "#{@name.capitalize} deployment",
          logger: @logger
        )
        @latest_rs.interpret_json_data(latest_rs_data)
        @rollout_data = compose_rollout_data(deployment_data["status"], @latest_rs.pods.length)
        @status = @rollout_data.map { |st, num| "#{num} #{st}" }.join(", ")
      end
    end

    def get_logs
      return {} unless @latest_rs
      @latest_rs.get_logs
    end

    def deploy_succeeded?
      return false unless @rollout_data.key?("availableReplicas")
      @rollout_data["updatedReplicasObserved"] == @rollout_data["replicas"] &&
      @rollout_data["updatedReplicas"].to_i == @rollout_data["replicas"].to_i &&
      @rollout_data["updatedReplicas"].to_i == @rollout_data["availableReplicas"].to_i
    end

    def deploy_failed?
      @latest_rs_pods.present? && @latest_rs_pods.all?(&:deploy_failed?)
    end

    def deploy_timed_out?
      super || @latest_rs_pods.present? && @latest_rs_pods.all?(&:deploy_timed_out?)
    end

    def exists?
      @found
    end

    private

    def get_latest_rs(deployment_data)
      label_string = deployment_data["spec"]["selector"]["matchLabels"].map { |k,v| "#{k}=#{v}" }.join(",")
      raw_json, _err, st = kubectl.run("get", "replicasets", "--output=json", "--selector=#{label_string}")
      return unless st.success?

      all_rs_data = JSON.parse(raw_json)["items"]
      current_revision = deployment_data["metadata"]["annotations"]["deployment.kubernetes.io/revision"]

      all_rs_data.find do |rs|
        rs["metadata"]["ownerReferences"].any? { |ref| ref["uid"] == deployment_data["metadata"]["uid"] } &&
        rs["metadata"]["annotations"]["deployment.kubernetes.io/revision"] == current_revision
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
