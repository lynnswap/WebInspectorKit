import Foundation
import PackagePlugin

@main
struct WebInspectorKitObfuscatePlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let sourceTarget = target as? SourceModuleTarget else {
            return []
        }

        let packageDir = context.package.directoryURL
        let obfuscateDir = try resolveObfuscateDirectory(from: packageDir)
        let scriptsDir = try resolveScriptsDirectory(for: sourceTarget)
        let configPath = obfuscateDir
            .appendingPathComponent("obfuscate.config.json")
        let scriptPath = obfuscateDir
            .appendingPathComponent("obfuscate.js")
        let outputFile = context.pluginWorkDirectoryURL
            .appendingPathComponent("BundledJavaScriptData.generated.swift")
        let mode = buildMode()

        var inputFiles = try collectJSFiles(in: scriptsDir)
        inputFiles.append(scriptPath)
        inputFiles.append(configPath)

        let nodeExecutable = try resolveNodeExecutable()

        return [
            .buildCommand(
                displayName: "Obfuscate JS (\(mode))",
                executable: nodeExecutable,
                arguments: [
                    scriptPath.path,
                    "--input",
                    scriptsDir.path,
                    "--output",
                    outputFile.path,
                    "--config",
                    configPath.path,
                    "--mode",
                    mode
                ],
                inputFiles: inputFiles,
                outputFiles: [outputFile]
            )
        ]
    }

    private func buildMode() -> String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["WEBINSPECTORKIT_OBFUSCATE_MODE"], !override.isEmpty {
            return override.lowercased()
        }
        if let config = env["SWIFT_BUILD_CONFIGURATION"] {
            return config.lowercased()
        }
        if let config = env["CONFIGURATION"] {
            return config.lowercased()
        }
        if let optimization = env["SWIFT_OPTIMIZATION_LEVEL"]?.lowercased() {
            if optimization == "-onone" {
                return "debug"
            }
            if optimization.hasPrefix("-o") {
                return "release"
            }
        }
        if let conditions = env["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] {
            let tokens = conditions
                .split { $0 == " " || $0 == ";" || $0 == "," }
                .map { $0.lowercased() }
            if tokens.contains("debug") {
                return "debug"
            }
            if !tokens.isEmpty {
                return "release"
            }
        }
        return "auto"
    }

    private func resolveObfuscateDirectory(from packageDir: URL) throws -> URL {
        let fileManager = FileManager.default
        let obfuscateDir = packageDir
            .appendingPathComponent("Plugins")
            .appendingPathComponent("WebInspectorKitObfuscatePlugin")
            .appendingPathComponent("ObfuscateJS")
        let script = obfuscateDir.appendingPathComponent("obfuscate.js")
        if fileManager.fileExists(atPath: script.path) {
            return obfuscateDir
        }

        throw PluginError("WebInspectorKitObfuscatePlugin/ObfuscateJS/obfuscate.js not found relative to package directory: \(packageDir.path)")
    }

    private func resolveScriptsDirectory(for target: SourceModuleTarget) throws -> URL {
        let fileManager = FileManager.default
        let scriptsDir = target.directoryURL
            .appendingPathComponent("TypeScript")
        if fileManager.fileExists(atPath: scriptsDir.path) {
            return scriptsDir
        }

        throw PluginError(
            "TypeScript script directory not found for target \(target.name): \(scriptsDir.path)"
        )
    }

    private func resolveNodeExecutable() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let overrideKey = "WEBINSPECTORKIT_NODE"
        if let override = env[overrideKey], !override.isEmpty {
            if FileManager.default.isExecutableFile(atPath: override) {
                return URL(fileURLWithPath: override)
            }
            throw PluginError("Invalid \(overrideKey): \(override)")
        }

        if let pathList = env["PATH"] {
            for dir in pathList.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("node")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        throw PluginError("node not found. Set WEBINSPECTORKIT_NODE to the node binary path (e.g. /opt/homebrew/bin/node).")
    }

    private func collectJSFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }
            if fileURL.pathExtension == "js" || fileURL.pathExtension == "ts" {
                results.append(fileURL)
            }
        }
        return results.sorted { $0.path < $1.path }
    }
}

private struct PluginError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
