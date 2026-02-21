import Foundation
import OSLog

// MARK: - LoggerPlugin

public struct LoggerPlugin: NetworkPlugin {
    public enum LogLevel: Sendable {
        case none
        case minimal
        case verbose
    }
    
    private let level: LogLevel
    private let logger: Logger?
    
    public init(level: LogLevel = .minimal, logger: Logger? = nil) {
        self.level = level
        self.logger = logger
    }
    
    // MARK: - NetworkPlugin
    
    public func willSend(request: URLRequest) async {
        guard level != .none else { return }
        
        #if DEBUG
        if level == .verbose {
            printVerboseRequest(request)
        } else {
            printMinimalRequest(request)
        }
        #endif
        
        if let logger = logger {
            logger.debug("🌐 \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
        }
    }
    
    public func didReceive(result: Result<(Data, URLResponse), Error>, for request: URLRequest) async {
        guard level != .none else { return }
        
        #if DEBUG
        switch result {
        case .success(let (data, response)):
            if level == .verbose {
                printVerboseResponse(data: data, response: response, request: request)
            } else {
                printMinimalResponse(response: response)
            }
            
        case .failure(let error):
            printError(error, for: request)
        }
        #endif
        
        if let logger = logger {
            switch result {
            case .success(let (_, response)):
                if let http = response as? HTTPURLResponse {
                    logger.debug("✅ \(http.statusCode)")
                }
            case .failure(let error):
                logger.error("❌ \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Private Helpers
    
    private func printMinimalRequest(_ request: URLRequest) {
        print("🌐 \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")")
    }
    
    private func printVerboseRequest(_ request: URLRequest) {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🌐 REQUEST")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("URL: \(request.url?.absoluteString ?? "nil")")
        print("Method: \(request.httpMethod ?? "nil")")
        
        if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            print("Headers:")
            headers.sorted(by: { $0.key < $1.key }).forEach { key, value in
                let sanitizedValue = key.lowercased().contains("authorization") ? "***" : value
                print("  \(key): \(sanitizedValue)")
            }
        }
        
        if let body = request.httpBody {
            if let json = try? JSONSerialization.jsonObject(with: body, options: []),
               let prettyData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
               let prettyString = String(data: prettyData, encoding: .utf8) {
                print("Body:")
                print(prettyString)
            } else if let string = String(data: body, encoding: .utf8) {
                print("Body:")
                print(string)
            }
        }
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    }
    
    private func printMinimalResponse(response: URLResponse) {
        guard let http = response as? HTTPURLResponse else { return }
        
        let emoji = (200..<300).contains(http.statusCode) ? "✅" : "⚠️"
        print("\(emoji) \(http.statusCode)")
    }
    
    private func printVerboseResponse(data: Data, response: URLResponse, request: URLRequest) {
        guard let http = response as? HTTPURLResponse else { return }
        
        let emoji = (200..<300).contains(http.statusCode) ? "✅" : "⚠️"
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("\(emoji) RESPONSE")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Status Code: \(http.statusCode)")
        print("URL: \(request.url?.absoluteString ?? "nil")")
        
        if let headers = http.allHeaderFields as? [String: Any], !headers.isEmpty {
            print("Headers:")
            headers.sorted(by: { "\($0.key)" < "\($1.key)" }).forEach { key, value in
                print("  \(key): \(value)")
            }
        }
        
        if !data.isEmpty {
            if let json = try? JSONSerialization.jsonObject(with: data, options: []),
               let prettyData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
               let prettyString = String(data: prettyData, encoding: .utf8) {
                print("Body:")
                print(prettyString)
            } else if let string = String(data: data, encoding: .utf8) {
                print("Body:")
                print(string)
            } else {
                print("Body: <binary data, \(data.count) bytes>")
            }
        }
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    }
    
    private func printError(_ error: Error, for request: URLRequest) {
        if level == .verbose {
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("❌ ERROR")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            print("URL: \(request.url?.absoluteString ?? "nil")")
            print("Error: \(error.localizedDescription)")
            
            if let networkError = error as? NetworkError,
               let data = networkError.responseData,
               let string = String(data: data, encoding: .utf8) {
                print("Response Data:")
                print(string)
            }
            
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
        } else {
            print("❌ \(error.localizedDescription)")
        }
    }
}
