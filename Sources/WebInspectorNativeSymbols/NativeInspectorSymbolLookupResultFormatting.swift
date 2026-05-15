#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

extension NativeInspectorSymbolResolverCore {
    @unsafe static func missingFunctionNames(
        in resolvedSymbols: NativeInspectorResolvedSymbolSet
    ) -> [String] {
        let symbolResults: [(String, ResolvedNativeInspectorAddress)] = [
            ("connectFrontend", resolvedSymbols.connectFrontend),
            ("disconnectFrontend", resolvedSymbols.disconnectFrontend),
            ("stringFromUTF8", resolvedSymbols.stringFromUTF8),
            ("stringImplToNSString", resolvedSymbols.stringImplToNSString),
            ("destroyStringImpl", resolvedSymbols.destroyStringImpl),
            ("backendDispatcherDispatch", resolvedSymbols.backendDispatcherDispatch),
        ]
        return symbolResults.compactMap { name, result in
            if case .missing = result {
                return name
            }
            return nil
        }
    }

    static func isFound(_ result: ResolvedNativeInspectorAddress) -> Bool {
        if case .found = result {
            return true
        }
        return false
    }

    static func debugResolvedAddress(_ result: ResolvedNativeInspectorAddress) -> String {
        switch result {
        case let .found(address):
            return unsafe String(format: "found(0x%llx)", address)
        case let .outsideText(address):
            return unsafe String(format: "outsideText(0x%llx)", address)
        case .missing:
            return "missing"
        }
    }

    static func failure(
        _ kind: NativeInspectorSymbolFailure,
        detail: String? = nil,
        phase: NativeInspectorSymbolResolutionPhase? = nil,
        source: String? = nil,
        missingFunctions: [String] = [],
        usedConnectDisconnectFallback: Bool = false,
        shouldLog: Bool = true
    ) -> NativeInspectorSymbolLookupResult {
        let reason = formattedFailureReason(
            kind: kind,
            detail: detail,
            phase: phase,
            source: source,
            missingFunctions: missingFunctions,
            usedConnectDisconnectFallback: usedConnectDisconnectFallback
        )
        if shouldLog {
            NativeInspectorSymbolLog.warning(
                "[WebInspectorNativeSymbols] native inspector symbol lookup failed backend=native-inspector reason=\(reason)"
            )
        }
        return NativeInspectorSymbolLookupResult(
            functionAddresses: .zero,
            failureReason: reason,
            failureKind: kind,
            phase: phase,
            missingFunctions: missingFunctions,
            source: source,
            usedConnectDisconnectFallback: usedConnectDisconnectFallback
        )
    }

    static func logResolutionAttemptIncomplete(
        _ result: NativeInspectorSymbolLookupResult,
        nextAttempt: String
    ) {
        guard let reason = result.failureReason, !reason.isEmpty else {
            return
        }
        NativeInspectorSymbolLog.info(
            "[WebInspectorNativeSymbols] native inspector symbol resolution attempt incomplete backend=native-inspector reason=\(reason) next=\(nextAttempt)"
        )
    }

    static func formattedFailureReason(
        kind: NativeInspectorSymbolFailure,
        detail: String?,
        phase: NativeInspectorSymbolResolutionPhase?,
        source: String?,
        missingFunctions: [String],
        usedConnectDisconnectFallback: Bool
    ) -> String {
        var parts = [String]()
        if let phase {
            parts.append("phase=\(phase.message)")
        }
        if let source, !source.isEmpty {
            parts.append("source=\(source)")
        }
        if !missingFunctions.isEmpty {
            parts.append("missing=\(missingFunctions.joined(separator: ","))")
        }
        if usedConnectDisconnectFallback {
            parts.append("textScanFallback=true")
        }
        if let detail, !detail.isEmpty {
            parts.append(detail)
        }
        if parts.isEmpty {
            return kind.message
        }
        return "\(kind.message): \(parts.joined(separator: " "))"
    }
}
#endif
