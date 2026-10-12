import Foundation
import Network

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
    public var bodyText: String { String(decoding: body, as: UTF8.self) }
}

public enum HTTPClientError: Error, Equatable {
    /// Nothing is listening on the socket. The request was never sent.
    case connectionFailed(String)
    /// The connection closed before any response arrived.
    case connectionLost(String)
    case timedOut
    case malformedResponse
}

/// Parses a complete HTTP/1.1 response, as received on a connection that the
/// server closes afterwards.
enum HTTPResponseParser {
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let lineTerminator = Data("\r\n".utf8)

    static func parse(_ data: Data) throws -> HTTPResponse {
        guard let split = data.range(of: headerTerminator) else { throw HTTPClientError.malformedResponse }
        let head = String(decoding: data[data.startIndex..<split.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPClientError.malformedResponse }

        // "HTTP/1.1 200 OK"
        let statusParts = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let status = Int(statusParts[1]) else {
            throw HTTPClientError.malformedResponse
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        var body = Data(data[split.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = decodeChunked(body) else { throw HTTPClientError.malformedResponse }
            body = decoded
        } else if let length = headers["content-length"].flatMap(Int.init), length >= 0, length < body.count {
            body = body.prefix(length)
        }
        return HTTPResponse(status: status, headers: headers, body: body)
    }

    /// Chunked transfer encoding: `<hex size>\r\n<bytes>\r\n … 0\r\n\r\n`.
    /// A stream cut off mid-chunk yields what arrived, which is the right
    /// answer for a log tail.
    static func decodeChunked(_ data: Data) -> Data? {
        var result = Data()
        var cursor = data.startIndex
        while cursor < data.endIndex {
            guard let lineEnd = data.range(of: lineTerminator, in: cursor..<data.endIndex) else { return nil }
            let sizeLine = String(decoding: data[cursor..<lineEnd.lowerBound], as: UTF8.self)
            // Anything after ";" is a chunk extension.
            let hex = sizeLine.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(hex, radix: 16), size >= 0 else { return nil }
            if size == 0 { return result }

            let start = lineEnd.upperBound
            let end = min(start + size, data.endIndex)
            result.append(data[start..<end])
            cursor = min(end + lineTerminator.count, data.endIndex)
        }
        return result
    }
}

/// A minimal HTTP/1.1 client for a unix domain socket, built on
/// Network.framework. One request per connection; the server closes it.
public struct UnixHTTPClient: Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(
        method: String = "GET",
        path: String,
        body: Data? = nil,
        timeout: TimeInterval = 10
    ) async throws -> HTTPResponse {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nUser-Agent: Strays\r\nAccept: */*\r\nConnection: close\r\n"
        if let body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        } else if method != "GET" {
            head += "Content-Length: 0\r\n"
        }
        var request = Data((head + "\r\n").utf8)
        if let body { request.append(body) }

        do {
            return try await exchange(request, timeout: timeout)
        } catch HTTPClientError.connectionFailed {
            // A busy daemon can refuse a connection when its accept queue is
            // momentarily full. Nothing was sent, so trying once more is safe.
            try await Task.sleep(for: .milliseconds(60))
            return try await exchange(request, timeout: timeout)
        }
    }

    private func exchange(_ request: Data, timeout: TimeInterval) async throws -> HTTPResponse {
        let exchange = Exchange(socketPath: socketPath, request: request, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exchange.start(continuation)
            }
        } onCancel: {
            exchange.cancel()
        }
    }
}

/// One request and its response. All state is confined to `queue`.
private final class Exchange: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "strays.unix-http")
    private var received = Data()
    private var isConnected = false
    private var continuation: CheckedContinuation<HTTPResponse, Error>?

    init(socketPath: String, request: Data, timeout: TimeInterval) {
        connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        self.request = request
        self.timeout = timeout
    }

    func start(_ continuation: CheckedContinuation<HTTPResponse, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                self?.stateChanged(to: state)
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(HTTPClientError.timedOut))
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.finish(.failure(CancellationError()))
        }
    }

    private func stateChanged(to state: NWConnection.State) {
        switch state {
        case .ready:
            isConnected = true
            sendRequest()
        case let .failed(error), let .waiting(error):
            // Before we are connected, either state means nothing is
            // listening: a unix socket has no network change to wait for.
            //
            // After that, the read decides. When the server closes the
            // socket, a state change can arrive ahead of the final read,
            // and acting on it would throw away a complete response.
            if !isConnected {
                finish(.failure(HTTPClientError.connectionFailed(error.localizedDescription)))
            }
        default:
            break
        }
    }

    private func sendRequest() {
        connection.send(content: request, completion: .contentProcessed { _ in })
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.received.append(data) }
            guard isComplete || error != nil else { return self.receive() }

            if self.received.isEmpty {
                let reason = error?.localizedDescription ?? "closed without a response"
                self.finish(.failure(HTTPClientError.connectionLost(reason)))
            } else {
                // The server closes the connection after each response, so
                // whatever arrived is the whole response.
                self.finish(Result { try HTTPResponseParser.parse(self.received) })
            }
        }
    }

    private func finish(_ result: Result<HTTPResponse, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
