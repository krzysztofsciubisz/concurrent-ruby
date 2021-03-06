require 'thread'
require 'observer'

require 'concurrent/dereferenceable'
require 'concurrent/global_thread_pool'
require 'concurrent/utilities'

module Concurrent

  # An agent is a single atomic value that represents an identity. The current value
  # of the agent can be requested at any time (#deref). Each agent has a work queue and operates on
  # the global thread pool. Consumers can #post code blocks to the agent. The code block (function)
  # will receive the current value of the agent as its sole parameter. The return value of the block
  # will become the new value of the agent. Agents support two error handling modes: fail and continue.
  # A good example of an agent is a shared incrementing counter, such as the score in a video game.
  class Agent
    include Observable
    include Dereferenceable
    include UsesGlobalThreadPool

    TIMEOUT = 5

    attr_reader :initial
    attr_reader :timeout

    def initialize(initial, opts = {})
      @value = initial
      @rescuers = []
      @validator = nil
      @timeout = opts[:timeout] || TIMEOUT
      init_mutex
      set_deref_options(opts)
    end

    def rescue(clazz = nil, &block)
      unless block.nil?
        mutex.synchronize do
          @rescuers << Rescuer.new(clazz, block)
        end
      end
      return self
    end
    alias_method :catch, :rescue
    alias_method :on_error, :rescue

    def validate(&block)
      @validator = block unless block.nil?
      return self
    end
    alias_method :validates, :validate
    alias_method :validate_with, :validate
    alias_method :validates_with, :validate

    def post(&block)
      Agent.thread_pool.post{ work(&block) } unless block.nil?
    end

    def <<(block)
      self.post(&block)
      return self
    end

    alias_method :add_watch, :add_observer

    private

    # @private
    Rescuer = Struct.new(:clazz, :block)

    # @private
    def try_rescue(ex) # :nodoc:
      rescuer = mutex.synchronize do
        @rescuers.find{|r| r.clazz.nil? || ex.is_a?(r.clazz) }
      end
      rescuer.block.call(ex) if rescuer
    rescue Exception => ex
      # supress
    end

    # @private
    def work(&handler) # :nodoc:
      begin
        mutex.synchronize do
          result = Concurrent::timeout(@timeout) do
            handler.call(@value)
          end
          if @validator.nil? || @validator.call(result)
            @value = result
            changed
          end
        end
        notify_observers(Time.now, self.value) if self.changed?
      rescue Exception => ex
        try_rescue(ex)
      end
    end
  end
end
