import Testing
@testable import WebInspectorNativeBridge
@testable import WebInspectorProxyKit
@testable import WebKitRuntime

struct NativeAttachmentErrorTests {
    @Test(arguments: [
        RuntimeLookupError.Reason.symbolMissing, .ambiguousSymbol, .invalidAddress, .imageUnavailable,
    ])
    func attachmentDiagnosticsPreserveLookupCategories(_ reason: RuntimeLookupError.Reason) throws {
        let error = NativeInspectorSymbolResolutionError(failures: [
            .init(role: .connectFrontend, underlyingError: RuntimeLookupError(reason)),
            .init(role: .stringFromUTF8, underlyingError: RuntimeLookupError(.symbolMissing)),
        ])
        let mapped = try #require(WebInspectorProxy.mapNativeAttachError(error) as? WebInspectorProxyError)
        guard case .unsupported(let diagnostics) = mapped else {
            Issue.record("Lookup failures must remain unsupported attachment errors.")
            return
        }
        #expect(diagnostics == [
            "Native Web Inspector requirement connectFrontend failed: \(reason.rawValue).",
            "Native Web Inspector requirement stringFromUTF8 failed: symbolMissing.",
        ])
    }
}
