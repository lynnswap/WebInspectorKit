import WebKitRuntime

enum NativeInspectorSymbolRole: String, Sendable {
    case connectFrontend, disconnectFrontend, stringFromUTF8, stringImplToNSString
    case derefStringImpl, dispatchMessageFromRemote, debuggableVTable
}
enum NativeInspectorSymbolOwnerImage: Sendable { case webKit, javaScriptCore }
enum NativeInspectorSymbolResolutionPolicy: Sendable { case requiredTextSymbol, requiredDataSymbol }
struct NativeInspectorSymbolQuery: Sendable {
    let declaration: String
    init(functionName: String, parameterTypes: [String]) {
        declaration = "\(functionName)(\(parameterTypes.joined(separator: ",")))"
    }
    init(vtableFor typeName: String) { declaration = "vtable for \(typeName)" }
}
struct NativeInspectorRequiredSymbol: Sendable {
    let role: NativeInspectorSymbolRole
    let ownerImage: NativeInspectorSymbolOwnerImage
    let queries: [NativeInspectorSymbolQuery]
    let resolutionPolicy: NativeInspectorSymbolResolutionPolicy
    func requirement(webKit: RuntimeImage, javaScriptCore: RuntimeImage) -> RuntimeSymbol {
        let images: [RuntimeImage] = role == .derefStringImpl ? [webKit, javaScriptCore] : [ownerImage == .webKit ? webKit : javaScriptCore]
        return RuntimeSymbol(names: queries.map { .cxx($0.declaration) }, in: images,
                             kind: resolutionPolicy == .requiredTextSymbol ? .function : .vtable)
    }
}
struct NativeInspectorSymbols: Sendable {
    let connectFrontend: NativeInspectorRequiredSymbol
    let disconnectFrontend: NativeInspectorRequiredSymbol
    let debuggableVTable: NativeInspectorRequiredSymbol
    let stringFromUTF8: NativeInspectorRequiredSymbol
    let stringImplToNSString: NativeInspectorRequiredSymbol
    let derefStringImpl: NativeInspectorRequiredSymbol
    let dispatchMessageFromRemote: NativeInspectorRequiredSymbol
    var all: [NativeInspectorRequiredSymbol] {
        [connectFrontend, disconnectFrontend, stringFromUTF8, stringImplToNSString,
         derefStringImpl, dispatchMessageFromRemote, debuggableVTable]
    }
}
