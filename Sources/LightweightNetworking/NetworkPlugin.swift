import Foundation

// MARK: - NetworkPlugin

public protocol NetworkPlugin: Sendable {
    func willSend(request: URLRequest) async
    func didReceive(result: Result<(Data, URLResponse), Error>, for request: URLRequest) async
}

// MARK: - Default Implementation

extension NetworkPlugin {
    public func willSend(request: URLRequest) async {}
    public func didReceive(result: Result<(Data, URLResponse), Error>, for request: URLRequest) async {}
}
