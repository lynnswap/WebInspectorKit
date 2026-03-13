package enum WISPISymbols {
    package static func deobfuscate(_ reverseTokens: [String]) -> String {
        reverseTokens.reversed().joined()
    }

    package static let worldWithConfigurationSelector = deobfuscate([":", "Configuration", "With", "world", "_"])
    package static let publicAddBufferSelector = deobfuscate([":", "World", "content", ":", "name", ":", "Buffer", "add"])
    package static let publicRemoveBufferSelector = deobfuscate([":", "World", "content", ":", "Name", "With", "Buffer", "remove"])
    package static let privateAddBufferSelector = deobfuscate([":", "name", ":", "World", "content", ":", "Buffer", "add", "_"])
    package static let privateRemoveBufferSelector = deobfuscate([":", "World", "content", ":", "Name", "With", "Buffer", "remove", "_"])
    package static let setResourceLoadDelegateSelector = deobfuscate([":", "Delegate", "Load", "Resource", "set", "_"])
    package static let allocSelector = deobfuscate(["alloc"])
    package static let initWithDataSelector = deobfuscate([":", "Data", "With", "init"])

    package static let contentWorldConfigurationClass = deobfuscate(["Configuration", "World", "Content", "WK", "_"])
    package static let privateJSHandleClass = deobfuscate(["Handle", "JS", "WK", "_"])
    package static let publicJSHandleClass = deobfuscate(["Handle", "JS", "WK"])
    package static let privateSerializedNodeClass = deobfuscate(["Node", "Serialized", "WK", "_"])
    package static let publicSerializedNodeClass = deobfuscate(["Node", "Serialized", "JS", "WK"])
    package static let privateJSBufferClass = deobfuscate(["Buffer", "JS", "WK", "_"])
    package static let publicJSScriptingBufferClass = deobfuscate(["Buffer", "Scripting", "JS", "WK"])

    package static let setUnobscuredSafeAreaInsetsSelector = deobfuscate([":", "Insets", "Area", "Safe", "Unobscured", "set", "_"])
    package static let setObscuredInsetEdgesAffectedBySafeAreaSelector = deobfuscate([":", "Area", "Safe", "By", "Affected", "Edges", "Inset", "Obscured", "set", "_"])
    package static let inputViewBoundsInWindowSelector = deobfuscate(["Window", "In", "Bounds", "View", "input", "_"])

    package static let enableJSHandleSetterNames = [
        deobfuscate([":", "Creation", "Handle", "JS", "Allow", "set"]),
        deobfuscate([":", "Enabled", "Creation", "Handle", "JS", "set"]),
    ]
    package static let enableNodeSerializationSetterNames = [
        deobfuscate([":", "Serialization", "Node", "Allow", "set"]),
        deobfuscate([":", "Enabled", "Serialization", "Node", "set"]),
    ]
}
