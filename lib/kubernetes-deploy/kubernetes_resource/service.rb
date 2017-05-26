# frozen_string_literal: true
module KubernetesDeploy
  class Service < KubernetesResource
    TIMEOUT = 5.minutes

    def sync
      _, _err, st = kubectl.run("get", type, @name)
      @found = st.success?
      if @found
        endpoints, _err, st = kubectl.run("get", "endpoints", @name, "--output=jsonpath={.subsets[*].addresses[*].ip}")
        @num_endpoints = (st.success? ? endpoints.split.length : 0)
      else
        @num_endpoints = 0
      end
      @status = "#{@num_endpoints} endpoints"
    end

    def deploy_succeeded?
      @num_endpoints > 0
    end

    def deploy_failed?
      false
    end

    def exists?
      @found
    end
  end
end
