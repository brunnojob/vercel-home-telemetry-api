require 'json'
require 'digest'
require 'fileutils'
require 'net/http'
require 'uri'
require 'openssl'
require 'securerandom'

module BrunnoDev
  class Outbox
    def initialize(directory, capacity: 1000)
      raise ArgumentError, 'positive capacity required' unless capacity.is_a?(Integer) && capacity.positive?
      @directory = File.expand_path(directory)
      @capacity = capacity
      FileUtils.mkdir_p(@directory, mode: 0o700)
      raise ArgumentError, 'symlink directory rejected' if File.symlink?(@directory)
      File.chmod(0o700, @directory)
    end

    def self.canonical(value)
      case value
      when Hash
        raise ArgumentError, 'string keys required' unless value.keys.all? { |key| key.is_a?(String) }
        value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array then value.map { |item| canonical(item) }
      when Float
        raise ArgumentError, 'finite numbers required' unless value.finite?
        value
      when String, Integer, TrueClass, FalseClass, NilClass then value
      else raise ArgumentError, 'JSON values required'
      end
    end

    def enqueue(project:, result:, kind: 'report', events: [], key: nil)
      raise ArgumentError, 'invalid project' unless /\A[a-zA-Z0-9_.-]{1,100}\z/.match?(project)
      raise ArgumentError, 'invalid kind' unless /\A[a-z][a-z0-9_.-]{0,63}\z/.match?(kind)
      raise ArgumentError, 'object result required' unless result.is_a?(Hash)
      raise ArgumentError, 'invalid events' unless events.is_a?(Array) && events.length <= 500 && events.all? { |e| e.is_a?(Hash) && JSON.generate(e).bytesize <= 16_384 }
      raise ArgumentError, 'result exceeds 192 KiB' if JSON.generate(result).bytesize > 196_608
      payload = self.class.canonical({ 'project' => project, 'kind' => kind, 'result' => result, 'events' => events })
      key ||= Digest::SHA256.hexdigest(JSON.generate(payload))
      raise ArgumentError, 'invalid idempotency key' unless key.is_a?(String) && key.bytesize.between?(1, 128)
      payload['clientKey'] = key
      raise ArgumentError, 'envelope exceeds 256 KiB' if JSON.generate(payload).bytesize > 262_144
      name = Digest::SHA256.hexdigest(project + "\0" + key)
      locked do
        path = File.join(@directory, name + '.json')
        if File.exist?(path)
          prior = read(path)
          raise ArgumentError, 'idempotency conflict' unless prior.fetch('payload') == payload
        else
          pending = paths.count { |item| read(item)['receipt'].nil? }
          raise RangeError, 'outbox full' if pending >= @capacity
          write(path, { 'payload' => payload, 'attempts' => 0, 'nextAt' => 0, 'receipt' => nil })
        end
      end
      key
    end

    def drain(endpoint:, token:, limit: 100, transport: nil, now: Time.now.to_f)
      raise ArgumentError, 'finite nonnegative time required' unless (now.is_a?(Integer) || now.is_a?(Float)) && now.finite? && now >= 0
      uri = URI.parse(endpoint)
      raise ArgumentError, 'HTTPS endpoint without credentials or fragment required' unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.fragment && !uri.query
      raise ArgumentError, 'invalid session token' unless token.is_a?(String) && /\A[A-Za-z0-9_.-]{1,8192}\z/.match?(token)
      raise ArgumentError, 'limit must be 1 to 1000' unless limit.is_a?(Integer) && limit.between?(1, 1000)
      delivered = 0
      locked do
        due = paths.filter_map do |path|
          item = read(path)
          [path, item] if !item['receipt'] && item.fetch('nextAt') <= now
        end.first(limit)
        due.each do |path, item|
          begin
            status, body = (transport || method(:request)).call(uri, token, JSON.generate(item.fetch('payload')))
            receipt = body.is_a?(String) && body.bytesize <= 16_384 ? JSON.parse(body) : nil
            if status.between?(200, 299) && receipt.is_a?(Hash) && receipt['persisted'] == true && receipt['clientKey'] == item.fetch('payload').fetch('clientKey') && receipt['id'].is_a?(String) && !receipt['id'].empty?
              item['receipt'] = { 'id' => receipt['id'], 'at' => now }
              delivered += 1
            else
              retry_later(item, now, "http_#{status}")
            end
          rescue StandardError => error
            retry_later(item, now, error.class.name)
          end
          write(path, item)
        end
      end
      delivered
    end

    def status
      locked do
        items = paths.map { |path| read(path) }
        { 'pending' => items.count { |i| i['receipt'].nil? }, 'delivered' => items.count { |i| i['receipt'] }, 'failedAttempts' => items.sum { |i| i.fetch('attempts') } }
      end
    end

    private

    def paths
      Dir.glob(File.join(@directory, '*.json')).sort
    end

    def read(path)
      raise IOError, 'symlink record rejected' if File.symlink?(path)
      raise IOError, 'record exceeds size limit' if File.size(path) > 524_288
      JSON.parse(File.binread(path, 524_289)).tap do |item|
        raise IOError, 'invalid record' unless item.is_a?(Hash) && item['payload'].is_a?(Hash) && item['attempts'].is_a?(Integer) && item['attempts'] >= 0 && (item['nextAt'].is_a?(Integer) || item['nextAt'].is_a?(Float)) && item['nextAt'].finite? && item['nextAt'] >= 0 && (item['receipt'].nil? || item['receipt'].is_a?(Hash))
      end
    end

    def write(path, item)
      temporary = path + '.' + SecureRandom.hex(8) + '.tmp'
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(JSON.generate(item))
          file.flush
          file.fsync
        end
        File.rename(temporary, path)
        File.open(@directory) { |directory| directory.fsync }
      ensure
        File.delete(temporary) if File.exist?(temporary)
      end
    end

    def locked
      path = File.join(@directory, '.lock')
      raise IOError, 'symlink lock rejected' if File.symlink?(path)
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        begin
          yield
        ensure
          file.flock(File::LOCK_UN)
        end
      end
    end

    def retry_later(item, now, error)
      item['attempts'] += 1
      item['lastError'] = error
      item['nextAt'] = now + [3600, 2**[item['attempts'], 12].min].min
    end

    def request(uri, token, payload)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 10
      http.read_timeout = 15
      http.write_timeout = 15
      request = Net::HTTP::Post.new(uri.request_uri)
      request['Authorization'] = "Bearer #{token}"
      request['Content-Type'] = 'application/json'
      request.body = payload
      status = 0
      body = +''
      http.start do |connection|
        connection.request(request) do |response|
          status = response.code.to_i
          response.read_body do |chunk|
            raise IOError, 'receipt too large' if body.bytesize + chunk.bytesize > 16_384
            body << chunk
          end
        end
      end
      [status, body]
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    outbox = BrunnoDev::Outbox.new(ENV.fetch('BRUNNODEV_OUTBOX', '.local/ruby-outbox'))
    case ARGV.shift
    when 'enqueue'
      project, path = ARGV
      raise ArgumentError, 'usage: enqueue PROJECT FILE.json' unless project && path && ARGV.length == 2
      data = File.binread(path, 196_609)
      raise ArgumentError, 'report too large' if data.bytesize > 196_608
      puts JSON.generate({ 'clientKey' => outbox.enqueue(project: project, result: JSON.parse(data)) })
    when 'sync'
      raise ArgumentError, 'usage: sync' unless ARGV.empty?
      endpoint = ENV.fetch('BRUNNODEV_API_URL').sub(%r{/\z}, '') + '/api/runs'
      puts JSON.generate({ 'delivered' => outbox.drain(endpoint: endpoint, token: ENV.fetch('BRUNNODEV_ACCESS_TOKEN')), 'status' => outbox.status })
    when 'status'
      raise ArgumentError, 'usage: status' unless ARGV.empty?
      puts JSON.generate(outbox.status)
    else raise ArgumentError, 'usage: outbox.rb enqueue PROJECT FILE.json | sync | status'
    end
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
