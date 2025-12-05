//
//  WIScript.swift
//  WebInspectorKit
//
//  Created by Codex on 2025/02/26.
//

import Foundation
import OSLog
import WebKit

private let scriptLogger = Logger(subsystem: "WebInspectorKit", category: "WIScript")

enum WIScript {
    @MainActor private static var cachedAgentScript: String?
    @MainActor private static var cachedNetworkScript: String?
    // Inline module sources to avoid CSP blocking external script loads in inspected pages.
    private static let agentModuleNames = [
        "InspectorAgent/InspectorAgentState",
        "InspectorAgent/InspectorAgentDOMCore",
        "InspectorAgent/InspectorAgentOverlay",
        "InspectorAgent/InspectorAgentSnapshot",
        "InspectorAgent/InspectorAgentSelection",
        "InspectorAgent/InspectorAgentDOMUtils",
        "InspectorAgent"
    ]
    private static let networkModuleNames = [
        "InspectorAgent/InspectorAgentNetwork",
        "InspectorNetworkAgent"
    ]

    @MainActor static func bootstrapAgent() throws -> String {
        if let cachedAgentScript {
            return cachedAgentScript
        }
        let script = try buildScript(from: agentModuleNames)
        cachedAgentScript = script
        return script
    }

    @MainActor static func bootstrapNetworkAgent() throws -> String {
        if let cachedNetworkScript {
            return cachedNetworkScript
        }
        let script = try buildScript(from: networkModuleNames)
        cachedNetworkScript = script
        return script
    }

    @MainActor private static func buildScript(from moduleNames: [String]) throws -> String {
        let body = try moduleNames
            .map { try loadModule(named: $0) }
            .joined(separator: "\n\n")

        let script = """
        (function() {
            "use strict";
        \(body)
        })();
        """
        return script
    }

    private static func loadModule(named name: String) throws -> String {
        let components = name.split(separator: "/").map(String.init)
        let fileName = components.last ?? name
        let subpath = components.dropLast().joined(separator: "/")

        let candidateSubdirectories = [
            ["WebInspector", "Support", subpath].filter { !$0.isEmpty }.joined(separator: "/"),
            "WebInspector/Support",
            nil
        ]

        var resolvedURL: URL?
        for subdir in candidateSubdirectories {
            if let url = WIAssets.locateResource(
                named: fileName,
                withExtension: "js",
                subdirectory: subdir
            ) {
                resolvedURL = url
                break
            }
        }

        guard let url = resolvedURL else {
            scriptLogger.error("missing web inspector module: \(name, privacy: .public)")
            throw WIError.scriptUnavailable
        }

        let rawSource: String
        do {
            rawSource = try String(contentsOf: url, encoding: .utf8)
        } catch {
            scriptLogger.error("failed to load web inspector module \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw WIError.scriptUnavailable
        }

        let withoutImports = rawSource
            // Remove single-line and multi-line import statements.
            .replacingOccurrences(
                of: #"(?ms)^\s*import[\s\S]*?;\s*$"#,
                with: "",
                options: [.regularExpression]
            )

        let trimmedImports = withoutImports
            .split(whereSeparator: \.isNewline)
            .map { $0 }
            .joined(separator: "\n")

        let strippedExports = trimmedImports
            .replacingOccurrences(
                of: #"export\s+(function|const|let|var)\s+"#,
                with: "$1 ",
                options: [.regularExpression]
            )
            .replacingOccurrences(
                of: #"(?ms)^\s*export\s+\{[\s\S]*?\}\s*;?\s*$"#,
                with: "",
                options: [.regularExpression]
            )

        return strippedExports
    }
}
