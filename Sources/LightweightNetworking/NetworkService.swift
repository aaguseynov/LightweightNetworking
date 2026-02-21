import Foundation

// MARK: - NetworkService

public protocol NetworkService: Sendable {
    func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response
    func request<E: Endpoint>(_ endpoint: E, taskId: UUID) async throws -> E.Response
    func cancelRequest(taskId: UUID) async
    func cancelAllRequests() async
}

// MARK: - Default Implementation

extension NetworkService {
    public func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response {
        try await request(endpoint, taskId: UUID())
    }
}
