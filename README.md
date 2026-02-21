# LightweightNetworking

Lightweight, type-safe networking library for iOS built with Swift Concurrency.

## Features

- **Swift 6.0** with full `Sendable` conformance
- **Actor-based** `NetworkClient` for thread-safe network operations
- **Protocol-oriented** architecture with `Endpoint` protocol for type-safe API definitions
- **Automatic retry logic** with configurable attempts
- **Request interceptors** for authentication and request modification
- **Plugin system** for extensibility (logging, analytics, etc.)
- **Built-in JSON encoding/decoding** with snake_case ↔ camelCase conversion
- **Comprehensive error handling** with `NetworkError` enum

## Requirements

- iOS 17.0+
- Swift 6.0+
- Xcode 16.0+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/aaguseynov/LightweightNetworking.git", from: "1.0.0")
]
```

Or in Xcode: File → Add Package Dependencies → Enter repository URL.

## Usage

### Define an Endpoint

```swift
struct GetUserEndpoint: Endpoint {
    typealias Response = User
    typealias Body = Never
    
    let baseURL = URL(string: "https://api.example.com")!
    let path = "/users/me"
    let method: HTTPMethod = .get
}
```

### Create a Network Client

```swift
let client = NetworkClient(
    interceptor: DefaultInterceptor(
        tokenProvider: { await tokenStorage.accessToken }
    ),
    plugins: [LoggerPlugin(level: .verbose)]
)
```

### Make Requests

```swift
do {
    let user = try await client.request(GetUserEndpoint())
    print("User: \(user.name)")
} catch let error as NetworkError {
    print("Error: \(error.errorDescription ?? "")")
}
```

### POST Request with Body

```swift
struct CreatePostEndpoint: Endpoint {
    typealias Response = Post
    typealias Body = CreatePostRequest
    
    let baseURL = URL(string: "https://api.example.com")!
    let path = "/posts"
    let method: HTTPMethod = .post
    var body: CreatePostRequest?
}

var endpoint = CreatePostEndpoint()
endpoint.body = CreatePostRequest(title: "Hello", content: "World")

let post = try await client.request(endpoint)
```

### Request Cancellation

```swift
let taskId = UUID()
let task = Task {
    try await client.request(endpoint, taskId: taskId)
}

// Cancel specific request
await client.cancelRequest(taskId: taskId)

// Cancel all requests
await client.cancelAllRequests()
```

## Components

### NetworkClient

The main actor for executing network requests. Handles request building, interceptor adaptation, plugin notifications, and retry logic.

### Endpoint Protocol

Defines API endpoints with associated types for request body and response:

```swift
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
```

### RequestInterceptor

Protocol for adapting requests and handling retries:

```swift
public protocol RequestInterceptor: Sendable {
    func adapt(_ request: URLRequest) async throws -> URLRequest
    func retry(_ error: NetworkError, for request: URLRequest, retryCount: Int) async -> RetryDecision
}
```

### DefaultInterceptor

Built-in interceptor with:
- Bearer token injection
- Automatic token refresh on 401 errors
- Configurable retry attempts

### NetworkPlugin

Protocol for monitoring network activity:

```swift
public protocol NetworkPlugin: Sendable {
    func willSend(request: URLRequest) async
    func didReceive(result: Result<(Data, URLResponse), Error>, for request: URLRequest) async
}
```

### LoggerPlugin

Built-in logging plugin with configurable verbosity levels:
- `.none` — No logging
- `.minimal` — HTTP method, URL, status code
- `.verbose` — Full request/response details including headers and body

### NetworkError

Comprehensive error handling:

```swift
public enum NetworkError: LocalizedError {
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
}
```

## License

MIT License. See [LICENSE](LICENSE) for details.
