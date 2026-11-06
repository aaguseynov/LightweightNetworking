import Foundation
import OSLog

public struct LoggerPlugin: NetworkPlugin {
    public enum LogLevel: Sendable { case none, minimal, verbose }
    private let level: LogLevel
    private let logger: Logger?
    private let redaction: LogRedactionPolicy

    public init(level: LogLevel = .minimal, logger: Logger? = nil, redaction: LogRedactionPolicy = LogRedactionPolicy()) {
        self.level = level
        self.logger = logger
        self.redaction = redaction
    }

    public func willSend(request: URLRequest) async {
        guard level != .none else { return }
        let message = requestDescription(request)
        #if DEBUG
        print(message)
        #endif
        logger?.debug("\(message)")
    }

    public func didReceive(result: Result<(Data, URLResponse), Error>, for request: URLRequest) async {
        guard level != .none else { return }
        let message = resultDescription(result)
        #if DEBUG
        print(message)
        #endif
        logger?.debug("\(message)")
    }

    func requestDescription(_ request: URLRequest) -> String {
        let summary = "REQUEST \(request.httpMethod ?? "GET")"
        guard level == .verbose else { return summary }
        return summary + " headers=\(redaction.redact(headers: request.allHTTPHeaderFields ?? [:])) bodyBytes=\(request.httpBody?.count ?? 0)"
    }

    func resultDescription(_ result: Result<(Data, URLResponse), Error>) -> String {
        switch result {
        case .success(let (data, response)):
            let response = response as? HTTPURLResponse
            let summary = "RESPONSE status=\(response?.statusCode ?? 0) bodyBytes=\(data.count)"
            guard level == .verbose, let response else { return summary }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) {
                $0[String(describing: $1.key)] = String(describing: $1.value)
            }
            return summary + " headers=\(redaction.redact(headers: headers))"
        case .failure(let error):
            if let error = error as? NetworkError, let code = error.statusCode { return "ERROR HTTP \(code)" }
            if error as? NetworkError == .cancelled || error is CancellationError { return "ERROR cancelled" }
            // Error descriptions can contain arbitrary server data, credentials, and URLs.
            return "ERROR request failed"
        }
    }
}
