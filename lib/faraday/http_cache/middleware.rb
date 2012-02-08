require 'active_support/core_ext/hash/slice'

module Faraday
  module HttpCache
    # Middleware object responsible for serving cached responses when
    # it's fresh enough to be used instead of requesting it to underlying
    # adapter on the `Faraday` stack.
    #
    # == Usage
    #
    # Configure your client to use the `:http_cache` middleware, as in:
    #
    #  client = Faraday.new do |builder|
    #    builder.user :http_cache
    #  end
    #
    # The middleware uses an `ActiveSupport` cache store to save the
    # cached responses. You can provide options to the middleware to create
    # a new store instance or use an existing object:
    #
    #  client = Faraday.new do |builder|
    #    builder.use :http_cache, :mem_cache_store
    #    # or
    #    builder.use :http_cache, Rails.cache
    #  end
    #
    # You can also provide a `:logger` option that will be used to
    # debug each request processed by the caching middleware.
    #
    #  client = Faraday.new do |builder|
    #    builder.use :http_cache, :logger => my_logger_instance
    #  end
    #
    # Cacheable responses will be stored and validated on each new request
    # to check if the response has expired - using the `Expires` header or a
    # `max-age` directive. Fresh responses will be updated and served instead
    # of issuing a new request to the targeted endpoint.
    class Middleware < Faraday::Middleware

      def initialize(app, *arguments)
        super(app)
        options = arguments.extract_options!

        @logger = options.delete(:logger)
        store = arguments.pop
        @storage = Storage.new(store, options)
      end

      def call(env)
        @trace = []

        request = env.slice(:method, :url, :request_headers)
        response = nil
        if can_cache?(request[:method])
          response = fetch(request) { @app.call(env) }
        else
          trace :unacceptable
          response = @app.call(env)
        end
        log(request)
        response
      end

      private
      # Only `GET` and `HEAD` requests should be cached.
      def can_cache?(method)
        method == :get || method == :head
      end

      # Tries to fetch an existing response for the current request
      # and check it's freshness. In the case of a stale response, the
      # call will bubble down the stack to retrieve a new response from
      # the underlying adapter.
      # Before serving the response back to the stack, the response will
      # be stored (or updated, if already present) inside the cache store if
      # the response can be cached.
      def fetch(request)
        entry = @storage.read(request)

        if entry && entry.fresh?
          response = entry
          trace :fresh
        else
          response = Response.new(yield.marshal_dump)
          trace :miss
        end

        if response.cacheable?
          @storage.write(request, response)
          trace :store
        else
          trace :invalid
        end
        response.to_response
      end

      # Records a step from the middleware's operation
      # that will be logger once it's finished.
      def trace(operation)
        @trace << operation
      end


      # Logs the HTTP method, request path and which
      # steps were executed during the middleware operation.
      def log(request)
        return unless @logger

        method = request[:method].to_s.upcase
        path = request[:url].path
        line = "HTTP Cache: [#{method} #{path}] #{@trace.join(', ')}"
        @logger.debug(line)
      end
    end
  end
end