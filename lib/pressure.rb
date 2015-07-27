require_relative 'pressure/version'
require 'logger'
require 'time'
require 'json'

class Pressure
  attr_accessor :wrapper_template
  attr_reader :sockets
  attr_reader :options

  def initialize(options = {}, &data_source_block)
    @wrapper_template = {}
    @current_upstream = {}
    @send_queue = Queue.new
    @options = options
    @sockets = []
    @websocket_worker_delay = options[:websocket_worker_delay] || (1.0 / 20.0)
    incoming_monitor(&data_source_block)
    websocket_worker_loop
  end

  def <<(socket)
    @sockets << socket
  end

  def delete(socket)
    @sockets.delete socket
  end

  def wrap_data(data)
    @wrapper_template.merge(upstream_data: data.clone,
                            last_update_ts: Time.now.utc.to_i)
  end

  def data_changed?(current_data, previous_data)
    current_data != previous_data
  end

  def incoming_monitor(&data_source_block)
    Thread.new do
      begin
        data = {}
        loop do
          upstream_data = data_source_block.call
          if data_changed?(data[:upstream_data], upstream_data)
            data = wrap_data(upstream_data)
            if @options[:no_wrap]
              @send_queue << upstream_data
            else
              @send_queue << data
            end
          end
          sleep(1.0 / 20.0)
        end
      rescue => e
        puts "error #{e}"
      end
    end
  end

  def websocket_worker
    # logger.info data.inspect
    queued_data = JSON.generate(@send_queue.shift)
    @sockets.each do |socket|
      socket.send queued_data
    end
  end

  def websocket_worker_loop
    Thread.new do
      begin
        loop do
          websocket_worker
          sleep(@websocket_worker_delay)
        end
      rescue => e
        puts "Worker error: #{e}"
        retry
      end
    end
  end
end
