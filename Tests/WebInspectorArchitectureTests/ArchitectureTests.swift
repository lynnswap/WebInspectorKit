import Foundation
import Testing

@Test
func uiDoesNotParseRawProtocolJSON() throws {
    let violations = try sourceFiles(under: "Sources/WebInspectorUI")
        .filter { try fileContents($0).contains("JSONSerialization") }
        .map(relativePath)

    #expect(violations.isEmpty, "WebInspectorUI must not parse raw protocol JSON: \(violations)")
}

@Test
func importBoundariesMatchArchitectureOverview() throws {
    let nativeBridgeViolations = try files(under: "Sources/WebInspectorNativeBridge")
        .filter { url in
            try importLines(in: url).contains { line in
                line.contains("WebInspectorTransport")
                    || line.contains("WebInspectorCore")
                    || line.contains("WebInspectorUI")
                    || line.contains("WebInspectorKit")
            }
        }
        .map(relativePath)

    let transportViolations = try sourceFiles(under: "Sources/WebInspectorTransport")
        .filter { url in
            let contents = try fileContents(url)
            return contents.contains("import WebInspectorCore")
                || contents.contains("import WebInspectorUI")
                || contents.contains("import WebInspectorKit")
        }
        .map(relativePath)

    let coreViolations = try sourceFiles(under: "Sources/WebInspectorCore")
        .filter { url in
            let contents = try fileContents(url)
            return contents.contains("import WebInspectorUI")
                || contents.contains("import WebInspectorKit")
        }
        .map(relativePath)

    #expect(nativeBridgeViolations.isEmpty, "NativeBridge must not import upper layers: \(nativeBridgeViolations)")
    #expect(transportViolations.isEmpty, "Transport must not import Core/UI/Kit: \(transportViolations)")
    #expect(coreViolations.isEmpty, "Core must not import UI/Kit: \(coreViolations)")
}

@Test
func exportedImportIsLimitedToUmbrellaTarget() throws {
    let allowedPath = "Sources/WebInspectorKit/WebInspectorKit.swift"
    let violations = try sourceFiles(under: "Sources")
        .flatMap { url -> [String] in
            let path = relativePath(url)
            return try fileContents(url)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { lineNumber, line in
                    guard line.contains("@_exported import") else {
                        return nil
                    }
                    guard path == allowedPath,
                          line.trimmingCharacters(in: .whitespaces) == "@_exported import WebInspectorUI" else {
                        return "\(path):\(lineNumber + 1)"
                    }
                    return nil
                }
        }

    #expect(violations.isEmpty, "@_exported import is only allowed in \(allowedPath): \(violations)")
}

@Test
func productionSourcesDoNotContainTransportTestSupport() throws {
    let violations = try sourceFiles(under: "Sources")
        .filter { url in
            let contents = try fileContents(url)
            return contents.contains("FakeTransportBackend")
                || contents.contains("SentTargetMessage")
        }
        .map(relativePath)

    #expect(violations.isEmpty, "Transport test support must stay out of production sources: \(violations)")
}

@Test
func unsafeConcurrencyEscapeHatchesStayOnAllowlist() throws {
    let allowedFiles: Set<String> = [
        "Sources/WebInspectorCore/Inspector/AttachedInspection.swift",
        "Sources/WebInspectorCore/Inspector/TransportReceiver.swift",
        "Sources/WebInspectorCore/Runtime/RuntimeProtocol.swift",
        "Sources/WebInspectorNativeSymbols/DEBUG/NativeInspectorAttachSymbolDiagnostics.swift",
        "Sources/WebInspectorNativeSymbols/DEBUG/NativeInspectorAttachSymbolScanning.swift",
        "Sources/WebInspectorNativeSymbols/MachOKitSymbolLookup.swift",
        "Sources/WebInspectorNativeSymbols/NativeInspectorAttachEntryPointFallback.swift",
        "Sources/WebInspectorNativeSymbols/NativeInspectorLoadedImageLookup.swift",
        "Sources/WebInspectorNativeSymbols/NativeInspectorSymbolLookupResultFormatting.swift",
        "Sources/WebInspectorNativeSymbols/NativeInspectorSymbolResolver.swift",
        "Sources/WebInspectorTransport/NativeInspectorBackend.swift",
        "Sources/WebInspectorTransport/NativeInspectorBackendFactory.swift",
        "Sources/WebInspectorUI/DOM/Element/DOMElementViewController+Preview.swift",
        "Sources/WebInspectorUI/DOM/Tree/DOMTreeFindCoordinator.swift",
        "Sources/WebInspectorUI/DOM/Tree/DOMTreeTextView.swift",
    ]

    let markers = [
        "@unchecked Sendable",
        "@unsafe",
        "@preconcurrency",
        "nonisolated(unsafe)",
    ]
    let violations = try sourceFiles(under: "Sources")
        .filter { url in
            let contents = try fileContents(url)
            return markers.contains { contents.contains($0) }
                && allowedFiles.contains(relativePath(url)) == false
        }
        .map(relativePath)

    #expect(violations.isEmpty, "New concurrency escape hatches must be reviewed and allowlisted: \(violations)")
}

@Test
func detachedTaskUsageStaysOnAllowlist() throws {
    let allowedFiles: Set<String> = [
        "Sources/WebInspectorCore/Network/NetworkBody.swift",
        "Sources/WebInspectorTransport/TransportMessageParser.swift",
        "Sources/WebInspectorUI/DOM/Tree/DOMTreeFindCoordinator.swift",
    ]

    let violations = try sourceFiles(under: "Sources")
        .filter { url in
            try fileContents(url).contains("Task.detached")
                && allowedFiles.contains(relativePath(url)) == false
        }
        .map(relativePath)

    #expect(violations.isEmpty, "Task.detached must stay limited to reviewed heavy-work paths: \(violations)")
}

private func packageRoot() throws -> URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let fileManager = FileManager.default
    while candidate.path != "/" {
        if fileManager.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    throw ArchitectureTestError.missingPackageRoot
}

private func files(under relativeDirectory: String) throws -> [URL] {
    let root = try packageRoot()
    let directory = root.appendingPathComponent(relativeDirectory)
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }
    return try enumerator.compactMap { element in
        guard let url = element as? URL else {
            return nil
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        return values.isRegularFile == true ? url : nil
    }
}

private func sourceFiles(under relativeDirectory: String) throws -> [URL] {
    try files(under: relativeDirectory)
        .filter { $0.pathExtension == "swift" }
}

private func fileContents(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

private func importLines(in url: URL) throws -> [String] {
    try fileContents(url)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("import ")
                || trimmed.hasPrefix("@")
                || trimmed.hasPrefix("#import ")
        }
}

private func relativePath(_ url: URL) -> String {
    let rootPath = (try? packageRoot().path) ?? ""
    return url.path.replacingOccurrences(of: rootPath + "/", with: "")
}

private enum ArchitectureTestError: Error {
    case missingPackageRoot
}
