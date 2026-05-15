#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

extension NativeInspectorSymbolResolverCore {
    @unsafe static func resolveConnectDisconnectFallbackIfNeeded(
        _ resolvedSymbols: NativeInspectorResolvedSymbolSet,
        image: MachOImage,
        text: SegmentCommand64,
        webCoreImage: MachOImage?,
        webCoreText: SegmentCommand64?,
        javaScriptCoreImage: MachOImage,
        javaScriptCoreText: SegmentCommand64,
        symbols: NativeInspectorSymbols
    ) -> NativeInspectorAttachEntryPointFallbackResult {
        let connectNeedsFallback: Bool
        switch resolvedSymbols.connectFrontend {
        case .missing, .outsideText:
            connectNeedsFallback = true
        case .found:
            connectNeedsFallback = false
        }

        let disconnectNeedsFallback: Bool
        switch resolvedSymbols.disconnectFrontend {
        case .missing, .outsideText:
            disconnectNeedsFallback = true
        case .found:
            disconnectNeedsFallback = false
        }

        guard connectNeedsFallback || disconnectNeedsFallback else {
            return .init(
                symbols: resolvedSymbols,
                usedFallback: false
            )
        }

        let webCoreConnectTargets = unsafe resolvedCallTargetAddresses(
            symbolNames: symbols.inspectorControllerConnectTargets.decodedCandidates(),
            in: webCoreImage,
            text: webCoreText
        )
        let webCoreDisconnectTargets = unsafe resolvedCallTargetAddresses(
            symbolNames: symbols.inspectorControllerDisconnectTargets.decodedCandidates(),
            in: webCoreImage,
            text: webCoreText
        )
        let webKitBoundConnectTargets = unsafe boundCallTargetAddresses(
            symbolNames: symbols.inspectorControllerConnectTargets.decodedCandidates(),
            in: image
        )
        let webKitBoundDisconnectTargets = unsafe boundCallTargetAddresses(
            symbolNames: symbols.inspectorControllerDisconnectTargets.decodedCandidates(),
            in: image
        )

        let connectTargetAddresses = webCoreConnectTargets.union(webKitBoundConnectTargets)
        let disconnectTargetAddresses = webCoreDisconnectTargets.union(webKitBoundDisconnectTargets)

        guard let functionStarts = image.functionStarts else {
            #if DEBUG
            NativeInspectorSymbolLog.info(
                String(
                    format: "[WebInspectorTransport] native inspector text scan unavailable functionStarts=nil webCoreConnectTargets=%lu webCoreDisconnectTargets=%lu webKitBoundConnectTargets=%lu webKitBoundDisconnectTargets=%lu",
                    webCoreConnectTargets.count,
                    webCoreDisconnectTargets.count,
                    webKitBoundConnectTargets.count,
                    webKitBoundDisconnectTargets.count
                )
            )
            #endif
            return .init(
                symbols: resolvedSymbols,
                usedFallback: false
            )
        }

        let webKitHeaderAddress = unsafe UInt64(UInt(bitPattern: image.ptr))
        let textRange = webKitHeaderAddress ..< webKitHeaderAddress + UInt64(text.virtualMemorySize)
        let functionStartAddresses = functionStarts
            .map { webKitHeaderAddress + UInt64($0.offset) }
            .filter { textRange.contains($0) }

        let resolvedConnect = unsafe resolvedFallbackFunctionStartAddress(
            in: image,
            text: text,
            functionStartAddresses: functionStartAddresses,
            callTargetAddresses: connectTargetAddresses
        )
        let resolvedDisconnect = unsafe resolvedFallbackFunctionStartAddress(
            in: image,
            text: text,
            functionStartAddresses: functionStartAddresses,
            callTargetAddresses: disconnectTargetAddresses
        )

        #if DEBUG
        NativeInspectorSymbolLog.info(
            String(
                format: "[WebInspectorTransport] native inspector text scan webCoreConnectTargets=%lu webCoreDisconnectTargets=%lu webKitBoundConnectTargets=%lu webKitBoundDisconnectTargets=%lu connectTargets=%lu disconnectTargets=%lu resolvedConnect=%@ resolvedDisconnect=%@",
                webCoreConnectTargets.count,
                webCoreDisconnectTargets.count,
                webKitBoundConnectTargets.count,
                webKitBoundDisconnectTargets.count,
                connectTargetAddresses.count,
                disconnectTargetAddresses.count,
                debugResolvedAddress(resolvedConnect),
                debugResolvedAddress(resolvedDisconnect)
            )
        )
        #endif

        let resolvedWrapperSymbols = NativeInspectorResolvedSymbolSet(
            connectFrontend: connectNeedsFallback && isFound(resolvedConnect) ? resolvedConnect : resolvedSymbols.connectFrontend,
            disconnectFrontend: disconnectNeedsFallback && isFound(resolvedDisconnect) ? resolvedDisconnect : resolvedSymbols.disconnectFrontend,
            stringFromUTF8: resolvedSymbols.stringFromUTF8,
            stringImplToNSString: resolvedSymbols.stringImplToNSString,
            destroyStringImpl: resolvedSymbols.destroyStringImpl,
            backendDispatcherDispatch: resolvedSymbols.backendDispatcherDispatch
        )
        let usedWrapperFallback =
            (connectNeedsFallback && isFound(resolvedConnect))
            || (disconnectNeedsFallback && isFound(resolvedDisconnect))

        return .init(
            symbols: resolvedWrapperSymbols,
            usedFallback: usedWrapperFallback
        )
    }

    @unsafe static func resolvedCallTargetAddresses(
        symbolNames: [String],
        in image: MachOImage?,
        text: SegmentCommand64?
    ) -> Set<UInt64> {
        guard let image, let text else {
            return []
        }
        var addresses = Set<UInt64>()
        for symbolName in symbolNames {
            let resolved = resolveLoadedImageSymbol(
                named: symbolName,
                in: image,
                text: text
            )
            if case let .found(address) = resolved {
                addresses.insert(address)
            }
        }
        return addresses
    }

    @unsafe static func boundCallTargetAddresses(
        symbolNames: [String],
        in image: MachOImage
    ) -> Set<UInt64> {
        let nameSet = Set(symbolNames)
        var addresses = Set<UInt64>()
        for bindingSymbol in image.bindingSymbols where nameSet.contains(bindingSymbol.symbolName) {
            if let address = bindingSymbol.address(in: image) {
                addresses.insert(UInt64(address))
            }
        }
        for bindingSymbol in image.lazyBindingSymbols where nameSet.contains(bindingSymbol.symbolName) {
            if let address = bindingSymbol.address(in: image) {
                addresses.insert(UInt64(address))
            }
        }
        if let indirectSymbols = image.indirectSymbols {
            let symbols = image.symbols
            for section in image.sections {
                guard let indirectSymbolIndex = section.indirectSymbolIndex,
                      let count = section.numberOfIndirectSymbols,
                      count > 0 else {
                    continue
                }
                let stride = section.size / count
                for elementIndex in 0 ..< count {
                    let indirectSymbol = indirectSymbols[indirectSymbolIndex + elementIndex]
                    guard let symbolIndex = indirectSymbol.index else {
                        continue
                    }
                    let symbolPosition = symbols.index(symbols.startIndex, offsetBy: symbolIndex)
                    let symbol = symbols[symbolPosition]
                    guard nameSet.contains(symbol.name) else {
                        continue
                    }
                    let address = section.address + stride * elementIndex
                    addresses.insert(UInt64(address))
                }
            }
        }
        return addresses
    }

    @unsafe static func resolvedFallbackFunctionStartAddress(
        in image: MachOImage,
        text: SegmentCommand64,
        functionStartAddresses: [UInt64],
        callTargetAddresses: Set<UInt64>
    ) -> ResolvedNativeInspectorAddress {
        guard !callTargetAddresses.isEmpty else {
            return .missing
        }
        let textPointer = unsafe image.ptr.assumingMemoryBound(to: UInt8.self)
        let imageBase = unsafe UInt64(UInt(bitPattern: image.ptr))
        let textBaseAddress = imageBase
        let textSize = Int(text.virtualMemorySize)
        let uniqueFunctionStart = unsafe uniqueFunctionStartContainingCallTargets(
            architecture: currentArchitectureName(),
            textBaseAddress: textBaseAddress,
            textPointer: textPointer,
            textSize: textSize,
            functionStartAddresses: functionStartAddresses,
            callTargetAddresses: callTargetAddresses
        )
        guard let uniqueFunctionStart else {
            return .missing
        }
        return .found(uniqueFunctionStart)
    }

    @unsafe static func uniqueFunctionStartContainingCallTargets(
        architecture: String,
        textBaseAddress: UInt64,
        textPointer: UnsafePointer<UInt8>,
        textSize: Int,
        functionStartAddresses: [UInt64],
        callTargetAddresses: Set<UInt64>
    ) -> UInt64? {
        guard !callTargetAddresses.isEmpty else {
            return nil
        }

        let sortedFunctionStarts = functionStartAddresses.sorted()
        var matches = Set<UInt64>()
        for (index, functionStart) in sortedFunctionStarts.enumerated() {
            let functionEnd = index + 1 < sortedFunctionStarts.count
                ? sortedFunctionStarts[index + 1]
                : textBaseAddress + UInt64(textSize)
            guard functionStart >= textBaseAddress, functionEnd > functionStart else {
                continue
            }
            let startOffset = Int(functionStart - textBaseAddress)
            let endOffset = Int(functionEnd - textBaseAddress)
            guard startOffset >= 0, endOffset <= textSize else {
                continue
            }
            if unsafe functionContainsCallTarget(
                architecture: architecture,
                textBaseAddress: textBaseAddress,
                textPointer: textPointer,
                startOffset: startOffset,
                endOffset: endOffset,
                callTargetAddresses: callTargetAddresses
            ) {
                matches.insert(functionStart)
            }
        }
        guard matches.count == 1 else {
            return nil
        }
        return matches.first
    }

    @unsafe static func functionContainsCallTarget(
        architecture: String,
        textBaseAddress: UInt64,
        textPointer: UnsafePointer<UInt8>,
        startOffset: Int,
        endOffset: Int,
        callTargetAddresses: Set<UInt64>
    ) -> Bool {
        #if arch(arm64) || arch(arm64e)
        if architecture == "arm64" || architecture == "arm64e" {
            var offset = startOffset
            while offset + MemoryLayout<UInt32>.size <= endOffset {
                let instruction = unsafe UnsafeRawPointer(textPointer.advanced(by: offset)).load(as: UInt32.self)
                if let target = decodedArm64BranchTarget(
                    instruction: instruction,
                    instructionAddress: textBaseAddress + UInt64(offset)
                ), callTargetAddresses.contains(target) {
                    return true
                }
                offset += MemoryLayout<UInt32>.size
            }
            return false
        }
        #endif

        if architecture == "x86_64" {
            var offset = startOffset
            while offset + 5 <= endOffset {
                if unsafe textPointer.advanced(by: offset).pointee == 0xE8,
                   let target = unsafe decodedX86CallTarget(
                    textPointer: textPointer,
                    callOffset: offset,
                    textBaseAddress: textBaseAddress
                   ),
                   callTargetAddresses.contains(target) {
                    return true
                }
                offset += 1
            }
        }
        return false
    }

    #if arch(arm64) || arch(arm64e)
    static func decodedArm64BranchTarget(
        instruction: UInt32,
        instructionAddress: UInt64
    ) -> UInt64? {
        // Match both `B` and `BL` immediate branches.
        let opcodeMask: UInt32 = 0x7C000000
        let branchOpcode: UInt32 = 0x14000000
        guard instruction & opcodeMask == branchOpcode else {
            return nil
        }

        let immediateMask: UInt32 = 0x03FFFFFF
        let immediate = Int32(bitPattern: instruction & immediateMask)
        let signedImmediate = (immediate << 6) >> 4
        let target = Int64(bitPattern: instructionAddress) + Int64(signedImmediate)
        guard target >= 0 else {
            return nil
        }
        return UInt64(target)
    }
    #endif

    static func decodedX86CallTarget(
        textPointer: UnsafePointer<UInt8>,
        callOffset: Int,
        textBaseAddress: UInt64
    ) -> UInt64? {
        let displacement = unsafe UnsafeRawPointer(textPointer).loadUnaligned(
            fromByteOffset: callOffset + 1,
            as: Int32.self
        )
        let nextInstructionAddress = Int64(textBaseAddress) + Int64(callOffset + 5)
        let target = nextInstructionAddress + Int64(displacement)
        guard target >= 0 else {
            return nil
        }
        return UInt64(target)
    }

    static func currentArchitectureName() -> String {
        #if arch(arm64e)
        return "arm64e"
        #elseif arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }
}
#endif
