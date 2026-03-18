import CryptoKit
import Foundation
import Testing
@testable import WebInspectorScripts

@MainActor
struct WebInspectorScriptsTests {
    @Test
    func bundledScriptsLoadFromCommittedGeneratedSwift() throws {
        #expect(try WebInspectorScripts.domAgent().isEmpty == false)
        #expect(try WebInspectorScripts.networkAgent().isEmpty == false)
        #expect(try WebInspectorScripts.domTreeView().isEmpty == false)
    }

    @Test
    func committedGeneratedBundleMatchesCurrentSourceInputs() throws {
        let expectedFingerprint = try Self.computeInputFingerprint()
        #expect(WebInspectorScripts.bundledScriptInputFingerprint == expectedFingerprint)
    }
}

private extension WebInspectorScriptsTests {
    static func computeInputFingerprint() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let inputDir = repoRoot.appendingPathComponent("Sources/WebInspectorScripts/TypeScript")
        let obfuscateDir = repoRoot.appendingPathComponent("Plugins/WebInspectorKitObfuscatePlugin/ObfuscateJS")

        let files = try collectScriptFiles(in: inputDir) + [
            obfuscateDir.appendingPathComponent("obfuscate.config.json"),
            obfuscateDir.appendingPathComponent("obfuscate.js"),
            obfuscateDir.appendingPathComponent("package.json"),
            obfuscateDir.appendingPathComponent("pnpm-lock.yaml"),
            obfuscateDir.appendingPathComponent("pnpm-workspace.yaml"),
        ]

        var hasher = SHA256()
        for fileURL in files.sorted(by: { $0.path < $1.path }) {
            let relativePath = fileURL.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: fileURL))
            hasher.update(data: Data([0]))
        }
        let hexDigits = Array("0123456789abcdef".utf8)
        return hasher.finalize().reduce(into: "") { result, byte in
            result.append(Character(UnicodeScalar(hexDigits[Int(byte >> 4)])))
            result.append(Character(UnicodeScalar(hexDigits[Int(byte & 0x0F)])))
        }
    }

    static func collectScriptFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
            if relativePath.hasPrefix("Tests/") || relativePath.contains("/node_modules/") {
                continue
            }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }
            if fileURL.pathExtension == "js" {
                results.append(fileURL)
                continue
            }
            if fileURL.pathExtension == "ts", fileURL.lastPathComponent.hasSuffix(".d.ts") == false {
                results.append(fileURL)
            }
        }
        return results
    }
}
