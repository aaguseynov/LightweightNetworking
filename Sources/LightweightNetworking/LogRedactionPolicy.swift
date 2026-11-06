import Foundation

/// Unknown headers are hidden. Bodies and URL paths/query are not logged.
public struct LogRedactionPolicy: Sendable {
    private let visibleHeaders: Set<String>

    public init(visibleHeaders: Set<String> = ["Accept", "Content-Type", "Content-Length"]) {
        self.visibleHeaders = Set(visibleHeaders.map { $0.lowercased() })
    }

    public func redact(headers: [String: String]) -> [String: String] {
        headers.mapValues { _ in "<redacted>" }.merging(
            headers.filter { visibleHeaders.contains($0.key.lowercased()) }
        ) { _, visible in visible }
    }
}
