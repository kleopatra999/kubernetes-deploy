# frozen_string_literal: true
module KubernetesDeploy
  class Deployment < KubernetesResource
    TIMEOUT = 5.minutes

    def sync
      raw_json, _err, st = kubectl.run("get", type, @name, "--output=json")
      @found = st.success?
      @rollout_data = { "replicas" => 0 }
      @status = nil
      @latest_rs = nil

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
        @latest_rs.deploy_started = @deploy_started

        @rollout_data.merge!(deployment_data["status"]
          .slice("replicas", "updatedReplicas", "availableReplicas", "unavailableReplicas"))
        @status = @rollout_data.map { |state_replicas, num| "#{num} #{state_replicas.chop.pluralize(num)}" }.join(", ")
      end
    end

    def fetch_events
      return {} unless @latest_rs.present?
      @latest_rs.fetch_events
    end

    def fetch_logs
      return {} unless @latest_rs.present?
      @latest_rs.fetch_logs
    end

    def deploy_succeeded?
      @latest_rs && @latest_rs.deploy_succeeded? &&
      @rollout_data["updatedReplicas"].to_i == @rollout_data["replicas"].to_i &&
      @rollout_data["updatedReplicas"].to_i == @rollout_data["availableReplicas"].to_i
    end

    def deploy_failed?
      @latest_rs && @latest_rs.deploy_failed?
    end

    def deploy_timed_out?
      super || @latest_rs && @latest_rs.deploy_timed_out?
    end

    def exists?
      @found
    end

    private

    def get_latest_rs(deployment_data)
      label_string = deployment_data["spec"]["selector"]["matchLabels"].map { |k, v| "#{k}=#{v}" }.join(",")
      raw_json, _err, st = kubectl.run("get", "replicasets", "--output=json", "--selector=#{label_string}")
      return unless st.success?

      all_rs_data = JSON.parse(raw_json)["items"]
      current_revision = deployment_data["metadata"]["annotations"]["deployment.kubernetes.io/revision"]

      all_rs_data.find do |rs|
        rs["metadata"]["ownerReferences"].any? { |ref| ref["uid"] == deployment_data["metadata"]["uid"] } &&
        rs["metadata"]["annotations"]["deployment.kubernetes.io/revision"] == current_revision
      end
    end
  end
end
