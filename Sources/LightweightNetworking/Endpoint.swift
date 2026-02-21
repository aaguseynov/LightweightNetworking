import Foundation

// MARK: - Endpoint

public protocol Endpoint: Sendable {
    associatedtype Response: Decodable & Sendable
    associatedtype Body: Encodable & Sendable
    
    var baseURL: URL { get }
    var path: String { get }
    var method: HTTPMethod { get }
    var headers: [String: String]? { get }
    var query: [String: String]? { get }
    var body: Body? { get set }
    var timeout: TimeInterval { get }
}

// MARK: - HTTPMethod

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

// MARK: - Default Implementation

extension Endpoint {
    public var headers: [String: String]? { nil }
    public var query: [String: String]? { nil }
    public var body: Body? { nil }
    public var timeout: TimeInterval { 30 }
}

// MARK: - Empty Response

public struct EmptyResponse: Decodable, Sendable {
    public init() {}
}
