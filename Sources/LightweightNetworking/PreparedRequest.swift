import Foundation

/// The actual request sent to transport, with an internal recovery snapshot.
public struct PreparedRequest: Sendable {
    public let request: URLRequest
    let refreshGeneration: UUID?
    let sessionEpoch: UUID?

    public init(request: URLRequest) {
        self.request = request
        refreshGeneration = nil
        sessionEpoch = nil
    }

    /// Use when composing adapters so recovery metadata survives request changes.
    public func replacingRequest(_ request: URLRequest) -> Self {
        Self(request: request, refreshGeneration: refreshGeneration, sessionEpoch: sessionEpoch)
    }

    init(request: URLRequest, refreshGeneration: UUID?, sessionEpoch: UUID?) {
        self.request = request
        self.refreshGeneration = refreshGeneration
        self.sessionEpoch = sessionEpoch
    }
}
