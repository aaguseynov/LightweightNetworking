import Foundation
import Testing
@testable import LightweightNetworking

@Suite
struct LoggerPluginTests {
    @Test func defaultAllowlistHidesUnknownHeaders() {
        let values = LogRedactionPolicy().redact(headers: ["Authorization": "secret", "Cookie": "cookie", "X-Custom-Token": "custom", "Content-Type": "application/json"])
        #expect(values["Authorization"] == "<redacted>")
        #expect(values["Cookie"] == "<redacted>")
        #expect(values["X-Custom-Token"] == "<redacted>")
        #expect(values["Content-Type"] == "application/json")
    }

    @Test func requestAndResponseDescriptionsNeverIncludeBodiesOrURLs() {
        let plugin = LoggerPlugin(level: .verbose)
        var request = URLRequest(url: URL(string: "https://example.invalid/private?token=query-secret")!)
        request.httpBody = Data("{\"password\":\"body-secret\"}".utf8)
        request.setValue("header-secret", forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": "cookie-secret"])!
        let output = plugin.requestDescription(request) + plugin.resultDescription(.success((Data("response-secret".utf8), response)))
        for secret in ["query-secret", "body-secret", "header-secret", "cookie-secret", "response-secret", "/private"] {
            #expect(!output.contains(secret))
        }
        #expect(output.contains("bodyBytes="))
        let failure = plugin.resultDescription(.failure(NetworkError.decodingError("secret-error")))
        #expect(!failure.contains("secret-error"))
    }
}
