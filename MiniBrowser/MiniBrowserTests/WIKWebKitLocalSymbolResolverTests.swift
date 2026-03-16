#if os(iOS) && DEBUG
import XCTest
@testable import MiniBrowser

@MainActor
final class WIKWebKitLocalSymbolResolverTests: XCTestCase {
    func testResolveCurrentWebKitAttachSymbolsReturnsAddressesOnSimulator() throws {
        #if targetEnvironment(simulator)
        let resolution = WIKWebKitLocalSymbolResolver.resolveCurrentWebKitAttachSymbols()
        let failureReason = resolution.failureReason
        let connectFrontendAddress = resolution.connectFrontendAddress
        let disconnectFrontendAddress = resolution.disconnectFrontendAddress
        XCTAssertNil(failureReason)
        XCTAssertNotEqual(connectFrontendAddress, 0)
        XCTAssertNotEqual(disconnectFrontendAddress, 0)
        #else
        throw XCTSkip("This smoke test only runs on the iOS simulator.")
        #endif
    }

    @MainActor
    func testResolveForTestingReportsFailureReasonForMissingSymbol() {
        let resolution = WIKWebKitLocalSymbolResolver.resolveForTesting(
            connectSymbol: "__ZN6WebKit26WebPageInspectorController27definitelyMissingConnectFooEv",
            disconnectSymbol: "__ZN6WebKit26WebPageInspectorController30definitelyMissingDisconnectBarEv"
        )

        let failureReason = resolution.failureReason
        let connectFrontendAddress = resolution.connectFrontendAddress
        let disconnectFrontendAddress = resolution.disconnectFrontendAddress
        XCTAssertNotNil(failureReason)
        XCTAssertEqual(connectFrontendAddress, 0)
        XCTAssertEqual(disconnectFrontendAddress, 0)
    }
}
#endif
