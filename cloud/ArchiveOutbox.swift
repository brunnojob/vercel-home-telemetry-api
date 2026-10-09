import Foundation
import CryptoKit
import CoreFoundation

enum ArchiveError: Error {
    case invalidInput, conflict, full, busy, invalidReceipt, insecureEndpoint
}

final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor ArchiveOutbox {
    private let directory: URL
    private let capacity: Int
    private var draining = false

    init(directory: URL, capacity: Int = 1000) throws {
        guard capacity > 0 else { throw ArchiveError.invalidInput }
        self.directory = directory
        self.capacity = capacity
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory
        else { throw ArchiveError.invalidInput }
    }

    private func encoded(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw ArchiveError.invalidInput }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func read(_ url: URL) throws -> [String: Any] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 524288,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        else { throw ArchiveError.invalidInput }
        return object
    }

    private func write(_ value: [String: Any], to url: URL) throws {
        try encoded(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func enqueue(project: String, result: Data, key: String? = nil) throws -> String {
        guard project.range(of: "^[a-zA-Z0-9_.-]{1,100}$", options: .regularExpression) != nil,
              result.count <= 196608,
              let object = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        else { throw ArchiveError.invalidInput }
        var payload: [String: Any] = ["project": project, "kind": "report", "result": object, "events": []]
        let identifier = key ?? SHA256.hash(data: try encoded(payload)).map { String(format: "%02x", $0) }.joined()
        guard !identifier.isEmpty, identifier.utf8.count <= 128 else { throw ArchiveError.invalidInput }
        payload["clientKey"] = identifier
        guard try encoded(payload).count <= 262144 else { throw ArchiveError.invalidInput }
        let filename = SHA256.hash(data: Data((project + "\0" + identifier).utf8)).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent(filename + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            let prior = try read(url)
            guard let stored = prior["payload"], try encoded(stored) == encoded(payload) else { throw ArchiveError.conflict }
        } else {
            let pending = try files().filter { try read($0)["receipt"] == nil }.count
            guard pending < capacity else { throw ArchiveError.full }
            try write(["payload": payload, "attempts": 0, "nextAt": 0], to: url)
        }
        return identifier
    }

    func sync(endpoint: URL, token: String, now: Date = Date()) async throws -> Int {
        guard endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil,
              endpoint.password == nil, endpoint.fragment == nil, endpoint.query == nil,
              token.range(of: "^[A-Za-z0-9_.-]{1,8192}$", options: .regularExpression) != nil
        else { throw ArchiveError.insecureEndpoint }
        guard !draining else { throw ArchiveError.busy }
        draining = true
        defer { draining = false }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var delivered = 0
        for url in try files().prefix(100) {
            var item = try read(url)
            guard item["receipt"] == nil,
                  (item["nextAt"] as? Double ?? 0) <= now.timeIntervalSince1970
            else { continue }
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                request.httpBody = try encoded(item["payload"] as Any)
                let (bytes, response) = try await session.bytes(for: request)
                var data = Data()
                for try await byte in bytes {
                    guard data.count < 16384 else { throw ArchiveError.invalidReceipt }
                    data.append(byte)
                }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      data.count <= 16384,
                      let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let persisted = receipt["persisted"] as? NSNumber,
                      CFGetTypeID(persisted) == CFBooleanGetTypeID(), persisted.boolValue,
                      let id = receipt["id"] as? String, !id.isEmpty,
                      receipt["clientKey"] as? String == (item["payload"] as? [String: Any])?["clientKey"] as? String
                else { throw ArchiveError.invalidReceipt }
                item["receipt"] = ["id": id, "at": now.timeIntervalSince1970]
                delivered += 1
            } catch {
                let attempts = (item["attempts"] as? Int ?? 0) + 1
                item["attempts"] = attempts
                item["nextAt"] = now.timeIntervalSince1970 + min(3600, pow(2, Double(min(attempts, 12))))
                item["lastError"] = String(describing: type(of: error))
            }
            try write(item, to: url)
        }
        return delivered
    }
}

@main struct ArchiveCLI {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let env = ProcessInfo.processInfo.environment
        if arguments == ["--self-test"] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let queue = try ArchiveOutbox(directory: dir, capacity: 1)
            let first = try await queue.enqueue(project: "swift", result: Data("{\"value\":1}".utf8))
            let duplicate = try await queue.enqueue(project: "swift", result: Data("{\"value\":1}".utf8))
            precondition(first == duplicate)
            do {
                _ = try await queue.enqueue(project: "swift", result: Data("{\"value\":2}".utf8), key: first)
                preconditionFailure("conflict accepted")
            } catch ArchiveError.conflict {}
            do {
                _ = try await queue.enqueue(project: "swift", result: Data("{\"value\":3}".utf8))
                preconditionFailure("capacity ignored")
            } catch ArchiveError.full {}
            do {
                _ = try await queue.sync(endpoint: URL(string: "http://example.com/api/runs")!, token: "a.b.c")
                preconditionFailure("HTTP accepted")
            } catch ArchiveError.insecureEndpoint {}
            print("Swift outbox checks passed")
            return
        }
        let queue = try ArchiveOutbox(directory: URL(fileURLWithPath: env["BRUNNODEV_OUTBOX"] ?? ".local/swift-outbox"))
        if arguments.count == 3, arguments[0] == "enqueue" {
            let url = URL(fileURLWithPath: arguments[2])
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 196608
            else { throw ArchiveError.invalidInput }
            print(try await queue.enqueue(project: arguments[1], result: Data(contentsOf: url)))
        } else if arguments == ["sync"], let base = env["BRUNNODEV_API_URL"],
                  let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/runs"),
                  let token = env["BRUNNODEV_ACCESS_TOKEN"] {
            print(try await queue.sync(endpoint: url, token: token))
        } else {
            throw ArchiveError.invalidInput
        }
    }
}
