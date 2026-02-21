import Foundation

// MARK: - NetworkError

public enum NetworkError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case encodingError(String)
    case decodingError(String)
    case serverError(statusCode: Int, data: Data?)
    case unauthorized
    case noData
    case timeout
    case cancelled
    case underlying(Error)
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
            
        case .invalidResponse:
            return "Invalid server response"
            
        case .encodingError(let message):
            return "Encoding failed: \(message)"
            
        case .decodingError(let message):
            return "Decoding failed: \(message)"
            
        case .serverError(let code, _):
            return "Server error with status code \(code)"
            
        case .unauthorized:
            return "Unauthorized (401)"
            
        case .noData:
            return "No data received"
            
        case .timeout:
            return "Request timeout"
            
        case .cancelled:
            return "Request cancelled"
            
        case .underlying(let error):
            return error.localizedDescription
        }
    }
    
    public var statusCode: Int? {
        if case .serverError(let code, _) = self {
            return code
        }
        if case .unauthorized = self {
            return 401
        }
        return nil
    }
    
    public var responseData: Data? {
        if case .serverError(_, let data) = self {
            return data
        }
        return nil
    }
    
    public var isAuthenticationError: Bool {
        if case .unauthorized = self {
            return true
        }
        return false
    }
    
    public var isServerError: Bool {
        if case .serverError(let code, _) = self, (500...599).contains(code) {
            return true
        }
        return false
    }
}

// MARK: - Equatable

extension NetworkError: Equatable {
    public static func == (lhs: NetworkError, rhs: NetworkError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidURL, .invalidURL),
             (.invalidResponse, .invalidResponse),
             (.unauthorized, .unauthorized),
             (.noData, .noData),
             (.timeout, .timeout),
             (.cancelled, .cancelled):
            return true
            
        case (.encodingError(let lMsg), .encodingError(let rMsg)):
            return lMsg == rMsg
            
        case (.decodingError(let lMsg), .decodingError(let rMsg)):
            return lMsg == rMsg
            
        case (.serverError(let lCode, _), .serverError(let rCode, _)):
            return lCode == rCode
            
        default:
            return false
        }
    }
}
