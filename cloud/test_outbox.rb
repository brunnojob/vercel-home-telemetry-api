require 'tmpdir'
require_relative 'outbox'

def check(value)
  raise 'assertion failed' unless value
end

Dir.mktmpdir do |directory|
  outbox = BrunnoDev::Outbox.new(directory, capacity: 2)
  key = outbox.enqueue(project: 'native', result: { 'total' => 10, 'currency' => 'BRL' })
  check(key == outbox.enqueue(project: 'native', result: { 'currency' => 'BRL', 'total' => 10 }))
  check(outbox.status['pending'] == 1)
  denied = false
  begin
    outbox.enqueue(project: 'native', key: key, result: { 'total' => 11 })
  rescue ArgumentError
    denied = true
  end
  check(denied)
  args = { endpoint: 'https://archive.example/api/runs', token: 'a.b.c', now: 1000 }
  check(outbox.drain(**args, transport: ->(*) { [200, '{"persisted":true}'] }) == 0)
  check(outbox.status['pending'] == 1)
  check(outbox.drain(**args, transport: ->(*) { raise 'backoff ignored' }) == 0)
  check(outbox.drain(**args.merge(now: 1100), transport: ->(*) { [302, '{"persisted":true,"id":"fake"}'] }) == 0)
  check(outbox.drain(**args.merge(now: 1200), transport: ->(*) { [200, JSON.generate({ 'persisted' => true, 'id' => 'saved', 'clientKey' => key })] }) == 1)
  check(BrunnoDev::Outbox.new(directory).status['delivered'] == 1)
  check(outbox.enqueue(project: 'native', result: { 'total' => 10, 'currency' => 'BRL' }) == key)
  check(outbox.status['pending'] == 0)
  denied = false
  begin
    outbox.drain(**args.merge(endpoint: 'http://archive.example/api/runs'))
  rescue ArgumentError
    denied = true
  end
  check(denied)
end
puts 'Ruby outbox checks passed'
