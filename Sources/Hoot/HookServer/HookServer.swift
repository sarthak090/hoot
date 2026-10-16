import Foundation
import Network
import HootCore

/// HTTP over a Unix domain socket in Hoot's private directory.
///
/// Every request must carry the bearer token. The head is validated before any body is
/// read; bodies are size-capped; slow or idle clients are dropped. `/permission`
/// connections stay open until the app answers or the client goes away.
final class HookServer: @unchecked Sendable {
    struct Request: Sendable {
        let route: HookRoute
        let body: Data
    }

    typealias Handler = @Sendable (Request, Responder) -> Void

    static let maxConnections = 64
    /// Time a client gets to deliver a complete request.
    static let readTimeout: TimeInterval = 10

    private let queue = DispatchQueue(label: "hoot.hookserver")
    private let expectedAuthorization: String
    private let handler: Handler
    // Confined to `queue`.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(expectedAuthorization: String, handler: @escaping Handler) {
        self.expectedAuthorization = expectedAuthorization
        self.handler = handler
    }

    func start(socketPath: String) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .unix(path: socketPath)
        params.allowLocalEndpointReuse = false
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                // Belt and braces: the directory is already 0700.
                chmod(socketPath, 0o600)
            }
            if case .failed(let error) = state {
                NSLog("Hoot: hook server failed: \(error)")
            }
        }
        queue.sync { self.listener = listener }
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    // MARK: - Connections (all on `queue`)

    private func accept(_ conn: NWConnection) {
        guard connections.count < Self.maxConnections else {
            conn.cancel()
            return
        }
        let key = ObjectIdentifier(conn)
        connections[key] = conn
        // Delivered on `queue`, the queue the connection is started on.
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[key] = nil
            default: break
            }
        }
        conn.start(queue: queue)

        let deadline = Deadline()
        queue.asyncAfter(deadline: .now() + Self.readTimeout) { [weak self] in
            guard !deadline.isCancelled else { return }
            self?.reject(conn, status: 408)
        }
        readHead(conn, buffer: Data(), deadline: deadline)
    }

    private func readHead(_ conn: NWConnection, buffer: Data, deadline: Deadline) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPParser.parseHead(buffer) {
            case .invalid(let status):
                deadline.cancel()
                self.reject(conn, status: status)
            case .needMore:
                if error != nil || isComplete {
                    deadline.cancel()
                    conn.cancel()
                } else {
                    self.readHead(conn, buffer: buffer, deadline: deadline)
                }
            case .complete(let head):
                switch HookRequestValidator.validate(head, expectedAuthorization: self.expectedAuthorization) {
                case .failure(let e):
                    deadline.cancel()
                    self.reject(conn, status: e.status)
                case .success(let route):
                    // Validated above, so this is a well-formed, capped integer.
                    let length = head.contentLength ?? 0
                    let body = buffer.dropFirst(head.bodyOffset)
                    self.readBody(conn, route: route, body: Data(body), length: length, deadline: deadline)
                }
            }
        }
    }

    private func readBody(_ conn: NWConnection, route: HookRoute, body: Data, length: Int, deadline: Deadline) {
        if body.count >= length {
            deadline.cancel()
            // Anything past Content-Length is ignored; we always close after one request.
            dispatch(conn, route: route, body: body.prefix(length))
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: min(length - body.count, 1 << 20)) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var body = body
            if let data { body.append(data) }
            if body.count < length, error != nil || isComplete {
                deadline.cancel()
                conn.cancel()
                return
            }
            self.readBody(conn, route: route, body: body, length: length, deadline: deadline)
        }
    }

    private func dispatch(_ conn: NWConnection, route: HookRoute, body: Data) {
        let responder = Responder(connection: conn, queue: queue)
        // A held /permission request ends early if the hook process dies (Claude Code
        // exited, the user answered and the session moved on, or the hook timed out).
        responder.watchForClose()
        handler(Request(route: route, body: body), responder)
    }

    private func reject(_ conn: NWConnection, status: Int) {
        conn.send(content: HTTPResponse.make(status: status), completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// Cancellation flag for the read timeout. Only touched on the server queue.
private final class Deadline: @unchecked Sendable {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}

/// Sends exactly one response on a held connection. Thread-safe; extra calls are ignored.
final class Responder: @unchecked Sendable {
    private enum State { case open, responded, clientGone }

    private let connection: NWConnection
    private let queue: DispatchQueue
    // Confined to `queue`.
    private var state = State.open
    private var goneHandlers: [@Sendable () -> Void] = []

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func respond(status: Int, body: Data = Data(), contentType: String = "application/json") {
        queue.async {
            guard self.state == .open else { return }
            self.state = .responded
            self.goneHandlers.removeAll()
            let conn = self.connection
            conn.send(content: HTTPResponse.make(status: status, body: body, contentType: contentType),
                      completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    /// Runs `handler` once if the client disconnects before a response was sent,
    /// including when that already happened before this call.
    func onClientGone(_ handler: @escaping @Sendable () -> Void) {
        queue.async {
            switch self.state {
            case .open: self.goneHandlers.append(handler)
            case .clientGone: handler()
            case .responded: break
            }
        }
    }

    fileprivate func watchForClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.clientGone()
            } else {
                // Stray bytes after the body: keep watching.
                self.watchForClose()
            }
        }
    }

    /// Always runs on `queue` (receive callbacks are delivered there).
    private func clientGone() {
        guard state == .open else { return }
        state = .clientGone
        let handlers = goneHandlers
        goneHandlers.removeAll()
        connection.cancel()
        handlers.forEach { $0() }
    }
}
