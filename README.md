# LightweightNetworking

A typed JSON networking package for iOS 17+ and Swift 6. URLSession transport, per-operation retries/cancellation, optional Bearer authorization, and observation plugins.

## 2.0.0 / compatibility

Version `2.0.0` is available under tag `v2.0.0`. The package name remains `LightweightNetworking`.
The error API adds `NetworkError.http(HTTPFailure)` and `RetryDecision.fail(NetworkError)`;
update exhaustive switches when migrating from 1.0.0. Endpoint authorization is now opt-in:
set `.required` or `.ifAvailable` on existing authenticated endpoints. Existing custom `adapt`/`retry` interceptors
continue to work through default protocol implementations.

## Endpoints

```swift
import Foundation
import LightweightNetworking

struct User: Decodable, Sendable { let id: Int }

struct GetUserEndpoint: Endpoint {
    typealias Response = User
    typealias Body = Never

    let baseURL = URL(string: "https://api.example.com")!
    let path = "/users/me"
    let method = HTTPMethod.get
    let authorization = AuthorizationRequirement.required
}
```

`Response` is `Decodable & Sendable`, `Body` is `Encodable & Sendable`. `body` requires only a getter;
immutable request DTOs and bodyless GET endpoints are supported. JSON encoding/decoding defaults
to snake_case and ISO-8601 dates; inject an encoder/decoder if the backend uses another format.
An explicit Content-Type is preserved. `EmptyResponse` supports 204 and successful empty responses.

## Composition

```swift
let interceptor = DefaultInterceptor(
    tokenProvider: { await tokenStorage.accessToken },
    refreshTokenProvider: {
        // Application-owned auth service refreshes AND persists credentials before returning.
        try await authService.refreshAndPersistAccessToken()
    },
    retryPolicy: RetryPolicy(maxRetries: 2)
)
let client = NetworkClient(
    interceptor: interceptor,
    plugins: [LoggerPlugin(level: .minimal)],
    maxRetryAttempts: 3,
    resourceTimeout: 30
)
let user = try await client.request(GetUserEndpoint())
```

`tokenStorage` and `authService` above belong to the application. The core does not implement
backend-specific refresh endpoints, credential persistence, business error decoding, or logout.
Use an unauthenticated base client for the refresh endpoint. A TaskLocal guard also prevents
recursive refresh through this interceptor if the same client is accidentally reused.

## Authorization

Endpoints declare `authorization`:

- `.none`: the default; do not apply configured Bearer credentials, and remove the standard Authorization header.
- `.ifAvailable`: explicitly apply credentials if available.
- `.required`: missing credentials fail before transport.

Declare `.none` on login/registration/refresh endpoints and `.required` on protected endpoints.
This policy concerns the configured authorization interceptor. URLSession cookie storage and
explicit Cookie headers are configured separately. The default implementation targets the standard
Authorization header; custom credential schemes override `prepare(_:authorization:)`.

## Refresh and session lifetime

A separate internal recovery actor coordinates one refresh and cancellable waiters. Each prepared
request captures a refresh generation. Late auth errors reuse the completed result, including
refresh failure, instead of refreshing again. A new request after a failed generation may try again.
Cancelling one waiter does not affect others; cancelling the last waiter cancels shared work.
A new caller arriving during cancellation waits for that refresh to finish before another starts.

The refresh provider must return a nonempty access token. Prefer persisting both access and rotated
refresh credentials before returning. If the access token has not been persisted yet, the interceptor
uses the returned value in memory while the provider still reports the previous token. This fallback
is cleared by a missing/changed credential or `reset()` and is not persistent storage.

On logout/account changes, the application must stop launching protected work, cancel requests,
clear its credential store and call `await interceptor.reset()`. Providers must cooperate with
cancellation and verify their session identity before persisting asynchronous results; the networking
package cannot undo writes to an external credential store. Technical refresh failures propagate as
technical errors and never trigger automatic logout.

## Cancellation and operation IDs

```swift
let id = UUID()
let task = Task { try await client.request(endpoint, taskId: id) }
await client.cancelRequest(taskId: id)
// Or cancel the caller: task.cancel()
// Or cancel all operations owned by this client:
await client.cancelAllRequests()
```

The client owns one task for the entire operation, including preprocessing, transport and backoff.
Registry entries are removed on success, failure and cancellation. IDs must be unique among active
calls; duplicate IDs fail with `.duplicateTaskID`. An ID can be reused after the previous call returns.
Cancellation is cooperative: custom async providers/plugins must also respond to cancellation.
The owned URLSession is invalidated when the client deinitializes.

## Whole-pipeline deadline

`NetworkClient(resourceTimeout: 30)` gives each accepted operation one monotonic 30-second budget.
The budget includes request encoding, async preparation and token lookup, HTTP transport, refresh
waiting, all retry backoffs/attempts, decoding, and observer hooks. Retries never restart this budget.
The default is `nil` (disabled); the application composition root chooses its own limit.

When the deadline expires, the operation is cancelled and the caller receives `NetworkError.timeout`.
This deadline is terminal for that operation and is not sent back into its retry policy. Explicit
cancellation by task ID, cancelAll, or the parent task remains `.cancelled`. A deadline affects only
its own operation; a shared refresh continues if another request still needs it.

This is cooperative cancellation, not thread preemption. Providers and plugins must support
cancellation. A noncooperative async callback can delay cleanup and return. Synchronous encoding
or decoding cannot be interrupted mid-call; budget checks reject a result that finishes too late.
The clock starts when the client accepts the call; waiting to enter a busy client actor is outside it.

`Endpoint.timeout` controls the URLRequest timeout for an individual attempt. URLSessionConfiguration
controls transport resource limits. Neither replaces the whole-pipeline `resourceTimeout`.

## Retries

Retry state belongs to each request call, never to an endpoint URL. Without an interceptor there
are no retries. `DefaultInterceptor` refreshes authentication only; transient retries are explicitly
opted into with `RetryPolicy`, which can also be used as an interceptor on its own.

- Capped exponential backoff and optional full jitter.
- Transient transport failures, timeout, and HTTP 408/429/500/502/503/504.
- Retry-After supports delta seconds and HTTP dates. Delays exceeding maxDelay are declined.
- GET/HEAD/OPTIONS/PUT/DELETE may replay; POST/PATCH require a nonempty Idempotency-Key.
  The backend must actually honor that key.
- Cancellation and decoding/validation failures are not transient.

`NetworkClient.maxRetryAttempts` is the total operation budget. Interceptor/policy limits may be
stricter and receive the total retry count already consumed by that operation. The client rejects
negative, nonfinite or unrepresentable retry delays rather than trapping.

## Errors and plugins

HTTP failures retain status, normalized lowercase headers, and body in `HTTPFailure`, available
through `statusCode`, `responseHeaders`, and `responseData`. HTTP 408/504 remain HTTP errors;
transport timeouts are `.timeout`. Legacy `.serverError` and `.unauthorized` cases remain available
for application/custom interceptor code. Backend-specific business errors are decoded by the caller.

Plugins receive the actual adapted request for each attempt and the response/attempt error.
They are observers; their async hooks cannot throw but must be lightweight and cancellation-aware.
When composing interceptors, forward `PreparedRequest` rather than reconstructing it; use
`replacingRequest` to keep recovery metadata when changing request headers.

`LoggerPlugin` omits URL paths/query and body contents at every verbosity. Verbose output adds
body sizes and headers filtered through `LogRedactionPolicy`. Unknown headers are masked by default;
only Accept, Content-Type and Content-Length are visible. Explicitly adding sensitive header names
to the allowlist opts into their disclosure. Arbitrary error descriptions are not logged.
Debug console output is compiled only in DEBUG; an optional OSLog Logger can be injected.

## Tests

The package includes URLProtocol integration tests and concurrency/HTTP/retry/logging unit tests:

```sh
xcodebuild -scheme LightweightNetworking \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro Max,OS=17.2' test
```

The current scope is foreground JSON requests. Binary/multipart uploads, download progress,
background transfers are separate capabilities, not implied by this API.

## License

MIT.
