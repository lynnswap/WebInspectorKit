import WebInspectorUIBase
import Foundation

extension NetworkDisplay {
    package struct URLSummary: Equatable, Sendable {
        package var rawURL: String
        package var displayName: String
        package var pathExtension: String?
        package var authority: String?
        package var decodedPath: String?
        package var searchTokens: [String]

        package init(url rawURL: String) {
            self.rawURL = rawURL

            guard rawURL.range(of: "data:", options: [.anchored, .caseInsensitive]) == nil else {
                self.displayName = rawURL
                self.pathExtension = nil
                self.authority = nil
                self.decodedPath = nil
                self.searchTokens = Self.uniqueNonEmpty([rawURL])
                return
            }

            guard let components = Self.components(for: rawURL) else {
                self.displayName = rawURL
                self.pathExtension = nil
                self.authority = nil
                self.decodedPath = nil
                self.searchTokens = Self.uniqueNonEmpty([rawURL])
                return
            }

            let encodedPath = components.percentEncodedPath
            let decodedPath = encodedPath.isEmpty ? nil : (encodedPath.removingPercentEncoding ?? encodedPath)
            let encodedLastSegment = encodedPath
                .split(separator: "/", omittingEmptySubsequences: true)
                .last
                .map(String.init)
            let lastSegment = encodedLastSegment.map { $0.removingPercentEncoding ?? $0 }
            let authority = Self.authority(from: components)
            let pathExtension = Self.pathExtension(from: lastSegment)
            let displayName = Self.firstNonEmpty([
                lastSegment,
                authority,
                decodedPath,
                rawURL,
            ]) ?? ""

            self.displayName = displayName
            self.pathExtension = pathExtension
            self.authority = authority
            self.decodedPath = decodedPath
            self.searchTokens = Self.uniqueNonEmpty([
                rawURL,
                displayName,
                authority,
                decodedPath,
                pathExtension,
            ])
        }

        private static func components(for rawURL: String) -> URLComponents? {
            if let components = URLComponents(string: rawURL, encodingInvalidCharacters: false) {
                return components
            }
            return URLComponents(string: rawURL, encodingInvalidCharacters: true)
        }

        private static func authority(from components: URLComponents) -> String? {
            guard let host = components.host, host.isEmpty == false else {
                return nil
            }
            guard let port = components.port else {
                return host
            }
            return "\(host):\(port)"
        }

        private static func pathExtension(from displayPathSegment: String?) -> String? {
            guard let displayPathSegment, displayPathSegment.isEmpty == false else {
                return nil
            }
            let fileName = displayPathSegment
                .split(separator: "/", omittingEmptySubsequences: false)
                .last
                .map(String.init) ?? displayPathSegment
            guard let periodIndex = fileName.lastIndex(of: "."),
                  periodIndex != fileName.startIndex,
                  periodIndex != fileName.index(before: fileName.endIndex) else {
                return nil
            }
            return String(fileName[fileName.index(after: periodIndex)...]).lowercased()
        }

        private static func firstNonEmpty(_ values: [String?]) -> String? {
            values.first { value in
                value?.isEmpty == false
            } ?? nil
        }

        private static func uniqueNonEmpty(_ values: [String?]) -> [String] {
            var seen: Set<String> = []
            var result: [String] = []
            for value in values {
                guard let value, value.isEmpty == false, seen.insert(value).inserted else {
                    continue
                }
                result.append(value)
            }
            return result
        }
    }
}
