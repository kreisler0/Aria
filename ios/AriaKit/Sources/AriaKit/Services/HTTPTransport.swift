import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 30) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Header names are lower-cased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// The one seam all networking goes through, so tests can substitute canned responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// `URLSession`-backed transport (continuation-based so it behaves the same on Linux).
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    continuation.resume(throwing: AriaError.network(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: AriaError.network("No HTTP response"))
                    return
                }
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key).lowercased()] = String(describing: value)
                }
                continuation.resume(returning: HTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
            }
            task.resume()
        }
    }
}

/// Percent-encodes query components strictly (RFC 3986 unreserved characters only), so
/// values such as `+05:00` offsets or PostgREST operators survive intact.
enum QueryEncoding {
    private static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// PostgREST reserves `,.:()` inside filter values; keep them readable in the
    /// structural parts and only escape inside values where needed.
    static func queryString(_ items: [(String, String)]) -> String {
        items.map { "\(encode($0.0))=\(encodeValue($0.1))" }.joined(separator: "&")
    }

    private static let valueAllowed: CharacterSet = {
        var set = unreserved
        set.insert(charactersIn: ",:()*")
        return set
    }()

    static func encodeValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? value
    }
}
