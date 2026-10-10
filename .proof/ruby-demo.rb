require 'tmpdir'
require 'json'
require 'open3'
require_relative '../cloud/outbox'
Dir.mktmpdir do |directory|
  first = BrunnoDev::Outbox.new(directory, capacity: 1)
  key = first.enqueue(project: 'telemetry-proof', result: { 'temperatureC' => 42.5 })
  recovered = BrunnoDev::Outbox.new(directory, capacity: 1)
  raise 'persistence failed' unless recovered.status['pending'] == 1
  replay = recovered.enqueue(project: 'telemetry-proof', result: { 'temperatureC' => 42.5 })
  raise 'replay failed' unless key == replay && recovered.status['pending'] == 1
  rejected = false
  begin
    recovered.enqueue(project: 'telemetry-proof', result: { 'temperatureC' => 43 })
  rescue RangeError
    rejected = true
  end
  raise 'capacity overflow accepted' unless rejected
  begin
    recovered.drain(endpoint: 'https://archive.example/api/runs', token: 'a.b.c', now: Float::NAN)
    raise 'nonfinite time accepted'
  rescue ArgumentError
  end
  report = recovered.status
  File.write(Dir.glob(File.join(directory, '*.json')).first, '{}')
  corrupt = false
  begin
    recovered.status
  rescue IOError
    corrupt = true
  end
  raise 'corrupt record accepted' unless corrupt
  puts JSON.generate({ 'recovered' => report, 'idempotent_replay' => true, 'capacity_rejected' => rejected, 'corrupt_record_rejected' => corrupt, 'network_requests' => 0 })
end
