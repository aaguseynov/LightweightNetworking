import Foundation

// MARK: - ResponseValidator

public struct ResponseValidator: Sendable {
    public static func validate(_ response: URLResponse?, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        
        switch httpResponse.statusCode {
        case 200..<300:
            return
            
        case 401:
            throw NetworkError.unauthorized
            
        case 408, 504:
            throw NetworkError.timeout
            
        default:
            throw NetworkError.serverError(statusCode: httpResponse.statusCode, data: data)
        }
    }
    
    public static func validateDataPresence(_ data: Data?, for statusCode: Int) throws {
        guard statusCode != 204 else { return }
        
        guard let data = data, !data.isEmpty else {
            throw NetworkError.noData
        }
    }
}
