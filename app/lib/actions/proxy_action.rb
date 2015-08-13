module Actions
  class ProxyAction < Base

    include ::Dynflow::Action::Cancellable

    class CallbackData
      attr_reader :data

      def initialize(data)
        @data = data
      end
    end

    def plan(proxy, options)
      options = default_connection_options.merge options
      plan_self(options.merge(:proxy_url => proxy.url))
    end

    def run(event = nil)
      case event
      when nil
        if output[:proxy_task_id]
          on_resume
        else
          trigger_proxy_task
        end
        suspend
      when ::Dynflow::Action::Skip
        # do nothing
      when ::Dynflow::Action::Cancellable::Cancel
        cancel_proxy_task
      when CallbackData
        if event.data[:result] == 'initialization_error'
          handle_proxy_exception(event.data[:exception_class]
                                  .constantize
                                  .new(event.data[:exception_message]))
        else
          on_data(event.data)
        end
      else
        raise "Unexpected event #{event.inspect}"
      end
    end

    def trigger_proxy_task
      response = proxy.trigger_task(proxy_action_name,
                                    input.merge(:callback => { :task_id => task.id,
                                                               :step_id => run_step_id }))
      output[:proxy_task_id] = response["task_id"]
    end

    def cancel_proxy_task
      if output[:cancel_sent]
        error! _("Cancel enforced: the task might be still running on the proxy")
      else
        proxy.cancel_task(output[:proxy_task_id])
        output[:cancel_sent] = true
        suspend
      end
    end

    def on_resume
      # TODO: add logic to load the data from the external action
      suspend
    end

    # @override to put custom logic on event handling
    def on_data(data)
      output[:proxy_output] = data
    end

    # @override String name of an action to be triggered on server
    def proxy_action_name
      raise NotImplemented
    end

    def proxy
      ProxyAPI::ForemanDynflow::DynflowProxy.new(:url => input[:proxy_url])
    end

    def proxy_output
      output[:proxy_output]
    end

    def proxy_output=(output)
      output[:proxy_output] = output
    end

    private

    def default_connection_options
      { :connection_options => { :retry_interval => 15, :retry_count => 4 } }
    end

    def handle_proxy_exception(exception)
      output[:failed_proxy_task_ids] ||= []
      options = input[:connection_options]
      if options[:retry_count] - output[:failed_proxy_task_ids].count > 0
        output[:failed_proxy_task_ids] << output[:proxy_task_id]
        output[:proxy_task_id] = nil
        suspend do |suspended_action|
          @world.clock.ping suspended_action,
                            Time.now + options[:retry_interval]
        end
      else
        raise exception
      end
    end
  end
end
