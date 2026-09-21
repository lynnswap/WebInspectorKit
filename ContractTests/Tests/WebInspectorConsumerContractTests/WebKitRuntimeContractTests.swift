import Darwin
import Foundation
import RuntimeConsumerNative
import Testing
import WebKit
import WebKitRuntime

struct WebKitRuntimeContractTests {
    @Test
    func externalConsumerResolvesOnlyItsOwnRequirements() async throws {
        let address = RuntimeConsumerAnchorAddress()
        guard let pointer = unsafe UnsafeRawPointer(bitPattern: address) else { throw CocoaError(.fileNoSuchFile) }
        var info = unsafe Dl_info()
        try #require(unsafe dladdr(pointer, &info) != 0)
        guard let path = unsafe info.dli_fname else { throw CocoaError(.fileNoSuchFile) }
        let image = RuntimeImage(pathSuffixes: [unsafe String(cString: path)])
        let query = RuntimeSymbol(.mangled("_RuntimeConsumerAnchorAddress"), in: image, kind: .function)
        let symbols = try await WebKitRuntime.resolve([query])
        #expect(symbols[0].address == UInt64(address))
        #expect(try symbols[0].readBytes(count: 4).count == 4)
    }

    @Test @MainActor
    func swiftAndObjectiveCConsumersSharePageAccess() throws {
        let view = WKWebView(frame: .zero)
        let swiftSize = try unsafe WebKitRuntime.withUnsafePage(of: view) { _, size in size }
        #expect(swiftSize > 0)
        #expect(swiftSize == RuntimeConsumerPageSize(view))
    }
}
