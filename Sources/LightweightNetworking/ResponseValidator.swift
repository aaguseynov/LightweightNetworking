import Foundation

// MARK: - ResponseValidator

public struct ResponseValidator: Sendable {
    public static func validate(_ response: URLResponse?, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        
        guard (200..<300).contains(httpResponse.statusCode) else {
            let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) {
                $0[String(describing: $1.key)] = String(describing: $1.value)
            }
            throw NetworkError.http(HTTPFailure(statusCode: httpResponse.statusCode, headers: headers, data: data))
        }
    }
    
    public static func validateDataPresence(_ data: Data?, for statusCode: Int) throws {
        guard statusCode != 204 else { return }
        
        guard let data = data, !data.isEmpty else {
            throw NetworkError.noData
        }
    }
}
