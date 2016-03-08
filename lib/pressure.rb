require 'hamster'
require 'json'
require 'logger'
require 'time'

require_relative 'pressure/version'

# Instances of the Pressure class can be used to read data from an upstream
# provider and broadcast it out to a set of downstream consumers.
#
# @!attribute [rw] logger
#   @return [Logger] Messages are logged to this object.
# @!attribute [r] sockets
#   @return [Hamster::Set<#send>] List of downstream sockets the instance is sending
#     to. These objects don't necessarily need to be sockets, as long as they
#     support a send method. Add objects to this list using the << method.
# @!attribute [rw] wrapper_template
#   @return [Hash] The template used to wrap upstream data before sending it
#     to downstream consumers. See wrap_data and the no_wrap option to
#     initialize.
class Pressure
  attr_writer :logger
  attr_reader :running
  attr_reader :sockets
  attr_accessor :wrapper_template

  # The default delay between loops of worker threads.
  DEFAULT_DELAY = (1.0 / 20.0)

  # Create a new Pressure instance and start reading data.
  #
  # @param options [Hash] Additional options.
  # @option options [Boolean] :no_wrap Data from upstream is wrapped in a JSON
  #   container by default, with some additional metadata. If this option is
  #   set to true, the data will be passed through without modification.
  # @option options [Float] :read_worker_delay The amount of time, in seconds,
  #   to sleep between attempts to read data from upstream. Defaults to
  #   DEFAULT_DELAY.
  # @option options [Float] :broadcast_worker_delay The amount of time, in
  #   seconds, to sleep between attempts to broadcast data to downstream
  #   sockets. Defaults to DEFAULT_DELAY.
  # @yield Block to call to read data from upstream.
  # @yieldreturn Data to send downstream.
  def initialize(options = {}, &data_source_block)
    @threads = []
    @wrapper_template = {}
    @current_upstream = {}
    @send_queue = Queue.new
    @sockets = Hamster::Set.new
    @broadcast_worker_delay = (options[:broadcast_worker_delay] ||
                               options[:websocket_worker_delay] ||
                               DEFAULT_DELAY)
    @read_worker_delay = (options[:read_worker_delay] ||
                          options[:incoming_monitor_delay] ||
                          DEFAULT_DELAY)
    @no_wrap = options[:no_wrap] || false
    @running = false
    @data_source_block = data_source_block
    start unless options[:start] == false
  end

  def logger
    @logger ||= Logger.new(STDERR).tap do |logger|
      logger.progname = 'pressure'
      logger.level = Logger::WARN
    end
  end

  # Add a downstream socket to the Pressure instance. The latest upstream
  # data will be immediately sent to the socket.
  #
  # @param socket [Socket, #send] A socket, or object that responds to #send.
  def <<(socket)
    new_sockets = @sockets.add? socket
    if new_sockets != false
      @sockets = new_sockets
      socket.send JSON.generate(@current_upstream)
    end
  end

  # Remove a downstream socket from the Pressure instance.
  #
  # @param socket [Socket, #send] A socket, or object that responds to #send,
  #   as added using <<.
  # @return the deleted socket object, or nil.
  def delete(socket)
    new_sockets = @sockets.delete? socket
    if new_sockets != false
      @sockets = new_sockets
      socket
    else
      nil
    end
  end

  # Start the worker threads.
  def start
    stop
    @running = true
    @threads << broadcast_worker_loop
    @threads << read_worker_loop
  end

  # Stop the worker threads.
  def stop
    @running = false
    @threads.each do |thread|
      thread.kill(5)
      thread.join
    end
    @threads = []
  end

  # @return [Boolean] true if the workers are running.
  def running?
    @running
  end

  protected

  # Wraps upstream data in a container to add metadata to the object.
  #
  # @param data Upstream data.
  # @return [Hash] wrapped data.
  def wrap_data(data)
    @wrapper_template.merge(upstream_data: Marshal.load(Marshal.dump(data)),
                            last_update_ts: Time.now.utc.to_i)
  end

  # Check whether two pieces of upstream data are different.
  #
  # @param current_data The most recent data read from upstream.
  # @param previous_data The last set of data read from upstream.
  # @return [Boolean] true if the data is different.
  def data_changed?(current_data, previous_data)
    if current_data && previous_data
      current_data != previous_data
    else
      true
    end
  end

  # Loop function for the thread reading data from the upstream provider.
  def read_worker_loop
    Thread.new do
      begin
        data = {}
        while @running
          upstream_data = @data_source_block.call
          if data_changed?(upstream_data, data[:upstream_data])
            data = wrap_data(upstream_data)
            @current_upstream = data
            if @no_wrap
              @send_queue << [upstream_data]
            else
              @send_queue << data
            end
          end
          sleep(@read_worker_delay)
        end
      rescue => e
        logger.error "Read worker error:"
        logger.error e
      end
    end
  end

  # Write data to downstream sockets.
  def broadcast
    queued_data = JSON.generate(@send_queue.shift)
    @sockets.each do |socket|
      socket.send queued_data
    end
  end

  # Loop function for the thread writing data to the downstream providers.
  def broadcast_worker_loop
    Thread.new do
      begin
        while @running
          broadcast
          sleep(@broadcast_worker_delay)
        end
      rescue => e
        logger.error "Broadcast worker error:"
        logger.error e
        retry
      end
    end
  end
end
