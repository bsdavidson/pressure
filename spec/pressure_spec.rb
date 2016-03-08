require 'socket'
require 'spec_helper'

describe Pressure do
  it 'has a version number' do
    expect(Pressure::VERSION).not_to be nil
  end

  describe '#initialize' do
    it 'allows a new instance to be created' do
      data_source_block = Proc.new {}
      expect_any_instance_of(Pressure).to receive(:start)
      p = Pressure.new &data_source_block
      expect(p.instance_variable_get(:@data_source_block)).to be(
        data_source_block)
      expect(p.instance_variable_get(:@broadcast_worker_delay)).to eql(
        Pressure::DEFAULT_DELAY)
      expect(p.instance_variable_get(:@read_worker_delay)).to eql(
        Pressure::DEFAULT_DELAY)
      expect(p.instance_variable_get(:@no_wrap)).to be false
    end

    it 'should allow you to not start the workers by default' do
      expect_any_instance_of(Pressure).to_not receive(:start)
      Pressure.new start: false
    end

    it 'should allow you to override the broadcast worker delay' do
      p = Pressure.new start: false, broadcast_worker_delay: 123
      expect(p.instance_variable_get(:@broadcast_worker_delay)).to eql 123
    end

    it 'should allow you to override the read worker delay' do
      p = Pressure.new start: false, read_worker_delay: 123
      expect(p.instance_variable_get(:@read_worker_delay)).to eql 123
    end
  end

  describe '#start' do
    it 'should allow you to start the workers' do
      p = Pressure.new start: false
      expect(p).to receive(:stop)
      broadcast_thread = double(Thread)
      expect(p).to receive(:broadcast_worker_loop).and_return(broadcast_thread)
      read_thread = double(Thread)
      expect(p).to receive(:read_worker_loop).and_return(read_thread)

      expect(p.instance_variable_get(:@running)).to be false
      expect(p.instance_variable_get(:@threads)).to eql []
      p.start
      expect(p.instance_variable_get(:@running)).to be true
      expect(p.instance_variable_get(:@threads)).to eql [broadcast_thread,
                                                         read_thread]
    end
  end

  describe '#stop' do
    it 'should allow you to stop the workers' do
      threads = [double(Thread), double(Thread)]
      threads.each do |thread|
        expect(thread).to receive(:kill).with(5).once
        expect(thread).to receive(:join).once
      end
      p = Pressure.new start: false
      p.instance_variable_set(:@running, true)
      p.instance_variable_set(:@threads, threads)
      p.stop
      expect(p.instance_variable_get(:@running)).to be false
      expect(p.instance_variable_get(:@threads)).to eql []
    end
  end

  describe '#<<' do
    it 'allows downstream sockets to be added to the instance' do
      socket1 = double('socket1')
      expect(socket1).to receive(:send).once.with('{}')
      p = Pressure.new start: false
      p << socket1
      expect(p.instance_variable_get(:@sockets)).to eq(
        Hamster::Set.new([socket1]))

      socket2 = double('socket2')
      expect(socket2).to receive(:send).once.with('{"foo":1}')
      p.instance_variable_set(:@current_upstream, {foo: 1})
      p << socket2
      expect(p.instance_variable_get(:@sockets)).to eq(
        Hamster::Set.new([socket1, socket2]))
    end

    it 'should not allow the same socket to be added more than once' do
      socket = double('socket')
      expect(socket).to receive(:send).once.with('{}')
      p = Pressure.new start: false
      p << socket
      p << socket
      expect(p.instance_variable_get(:@sockets)).to eq(
        Hamster::Set.new([socket]))
    end
  end

  describe '#delete' do
    it 'allows downstream sockets to be deleted from the instance' do
      socket1 = double('socket1')
      socket2 = double('socket2')
      p = Pressure.new start: false
      p.instance_variable_set(:@sockets, Hamster::Set.new([socket1, socket2]))
      expect(p.delete(socket1)).to be socket1
      expect(p.instance_variable_get(:@sockets)).to eq(
        Hamster::Set.new([socket2]))
    end

    it 'should return nil if delete is called with a socket not in the set' do
      socket = double('socket')
      p = Pressure.new start: false
      expect(p.delete(socket)).to be nil
    end
  end

  describe '#wrap_data' do
    it 'can wrap upstream data' do
      p = Pressure.new start: false
      now = Time.now
      wrapped_data = Timecop.freeze(now) do
        p.send(:wrap_data, 'foo')
      end
      expect(wrapped_data).to eql(upstream_data: 'foo',
                                  last_update_ts: now.utc.to_i)
    end
  end

  describe '#data_changed?' do
    it 'can compare two sets of upstream data' do
      p = Pressure.new start: false
      expect(p.send(:data_changed?, 'foo', 'bar')).to be true
      expect(p.send(:data_changed?, 'foo', 'foo')).to be false
    end

    it 'should consider data changed if the values are nil' do
      p = Pressure.new start: false
      expect(p.send(:data_changed?, nil, nil)).to be true
    end
  end

  describe '#read_worker_loop' do
    it 'runs a loop reading from upstream' do
      p = Pressure.new start: false

      counter = 0
      data_source_block = Proc.new do
        counter += 1
        case counter
        when 1
          'foo'
        when 2
          # This second value shouldn't be queued, because it should be considered
          # duplicate data from upstream.
          'foo'
        when 3
          # Terminate the loop after yielding 'bar'
          p.instance_variable_set(:@running, false)
          'bar'
        end
      end
      p.instance_variable_set(:@data_source_block, data_source_block)

      now = Time.now
      p.instance_variable_set(:@running, true)
      Timecop.freeze(now) do
        thread = p.send(:read_worker_loop)
        thread.join
      end

      queue = p.instance_variable_get(:@send_queue)
      expect(queue.length).to eql 2
      expect(queue.pop).to eql(upstream_data: 'foo',
                               last_update_ts: now.utc.to_i)
      expect(queue.pop).to eql(upstream_data: 'bar',
                               last_update_ts: now.utc.to_i)
    end
  end

  describe '#broadcast' do
    it 'broadcasts data to downstream sockets' do
      sockets = (0...3).map do |i|
        socket = double("socket#{i}")
        expect(socket).to receive(:send).once.with('["foo"]')
        expect(socket).to receive(:send).once.with('["bar"]')
        socket
      end

      queue = Queue.new
      queue << ['foo']
      queue << ['bar']

      p = Pressure.new start: false
      p.instance_variable_set(:@send_queue, queue)
      p.instance_variable_set(:@sockets, Hamster::Set.new(sockets))

      p.send(:broadcast)
      expect(queue.length).to eql 1

      p.send(:broadcast)
      expect(queue.length).to eql 0
    end
  end

  describe '#broadcast_worker_loop' do
    it 'runs a loop broadcasting to downstream sockets' do
      p = Pressure.new start: false
      counter = 0
      expect(p).to receive(:broadcast) {
        counter += 1
        p.instance_variable_set(:@running, false) if counter == 2
      }.exactly(2).times
      p.instance_variable_set(:@running, true)
      thread = p.send(:broadcast_worker_loop)
      thread.join
    end
  end
end
