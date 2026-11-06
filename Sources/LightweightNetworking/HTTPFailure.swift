import Foundation

/// HTTP errors retain the full response; transport timeouts remain a separate error.
public struct HTTPFailure: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data?

    public init(statusCode: Int, headers: [String: String] = [:], data: Data? = nil) {
        self.statusCode = statusCode
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        self.data = data
    }
}
