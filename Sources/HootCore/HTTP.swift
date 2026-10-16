import Foundation

/// The parsed request line and headers of an HTTP/1.x request.
public struct HTTPRequestHead: Sendable, Equatable {
    public var method: String
    public var path: String
    /// Header names are lowercased. Duplicate headers are rejected while parsing.
    public var headers: [String: String]
    /// Byte offset in the buffer where the body starts.
    public var bodyOffset: Int

    public var contentLength: Int? { headers["content-length"].flatMap { Int($0) } }
}

public enum HTTPHeadParse: Sendable, Equatable {
    case needMore
    case complete(HTTPRequestHead)
    case invalid(status: Int)
}

public enum HTTPParser {
    public static let maxHeaderBytes = 16 * 1024

    /// Parses the request head from the start of `buffer`. Strict on purpose: the only
    /// legitimate client is our own curl invocation.
    public static func parseHead(_ buffer: Data, maxHeaderBytes: Int = maxHeaderBytes) -> HTTPHeadParse {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: terminator) else {
            return buffer.count > maxHeaderBytes ? .invalid(status: 431) : .needMore
        }
        let headLength = end.lowerBound - buffer.startIndex
        guard headLength <= maxHeaderBytes else { return .invalid(status: 431) }
        guard let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400)
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3,
              requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0",
              requestLine[1].hasPrefix("/")
        else { return .invalid(status: 400) }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
            let name = line[..<colon].lowercased()
            // Header names never contain whitespace; obsolete line folding is rejected.
            guard !name.isEmpty, !name.contains(where: { $0 == " " || $0 == "\t" }) else { return .invalid(status: 400) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[name] == nil else { return .invalid(status: 400) }
            headers[name] = value
        }
        return .complete(HTTPRequestHead(method: String(requestLine[0]), path: String(requestLine[1]),
                                         headers: headers, bodyOffset: end.upperBound - buffer.startIndex))
    }
}

public enum HookRoute: String, Sendable {
    /// PermissionRequest: the connection is held until the user answers.
    case permission = "/permission"
    /// Notification / UserPromptSubmit: answered immediately.
    case event = "/event"
    /// Statusline JSON (plan rate limits); answered with the status line text.
    case statusline = "/statusline"
}

public enum HookRequestValidator {
    public static let maxBodyBytes = 8 * 1024 * 1024

    /// Returns the route, or the HTTP status to reject with. Checked as soon as the
    /// head arrives so nothing unauthenticated ever has its body read.
    public static func validate(_ head: HTTPRequestHead, expectedAuthorization: String) -> Result<HookRoute, HTTPStatusError> {
        guard let given = head.headers["authorization"],
              constantTimeEquals(given, expectedAuthorization)
        else { return .failure(HTTPStatusError(401)) }
        // Browsers always send one of these; our curl never does.
        if head.headers["origin"] != nil || head.headers["sec-fetch-mode"] != nil || head.headers["sec-fetch-site"] != nil {
            return .failure(HTTPStatusError(403))
        }
        guard head.method == "POST" else { return .failure(HTTPStatusError(405)) }
        guard let route = HookRoute(rawValue: head.path) else { return .failure(HTTPStatusError(404)) }
        if head.headers["transfer-encoding"] != nil { return .failure(HTTPStatusError(411)) }
        guard let length = head.headers["content-length"] else { return .failure(HTTPStatusError(411)) }
        guard let n = Int(length), n >= 0, String(n) == length else { return .failure(HTTPStatusError(400)) }
        guard n <= maxBodyBytes else { return .failure(HTTPStatusError(413)) }
        return .success(route)
    }

    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        // Always walk the expected value's length so timing doesn't depend on the input.
        for i in 0..<y.count {
            diff |= (i < x.count ? x[i] : 0) ^ y[i]
        }
        return diff == 0
    }
}

public struct HTTPStatusError: Error, Sendable, Equatable {
    public let status: Int
    public init(_ status: Int) { self.status = status }
}

public enum HTTPResponse {
    public static func make(status: Int, body: Data = Data(), contentType: String = "application/json") -> Data {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        if !body.isEmpty { head += "Content-Type: \(contentType)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}
