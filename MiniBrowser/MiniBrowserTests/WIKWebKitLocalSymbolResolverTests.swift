#if os(iOS) && DEBUG
import XCTest
@testable import MiniBrowser

final class WIKWebKitLocalSymbolResolverTests: XCTestCase {
    func testResolveCurrentWebKitAttachSymbolsReturnsAddressesOnSimulator() {
        #if targetEnvironment(simulator)
        let resolution = WIKWebKitLocalSymbolResolver.resolveCurrentWebKitAttachSymbols()
        XCTAssertNil(resolution.failureReason)
        XCTAssertNotEqual(resolution.connectFrontendAddress, 0)
        XCTAssertNotEqual(resolution.disconnectFrontendAddress, 0)
        #else
        throw XCTSkip("This smoke test only runs on the iOS simulator.")
        #endif
    }

    func testResolveForTestingReportsFailureReasonForMissingSymbol() {
        let resolution = WIKWebKitLocalSymbolResolver.resolveForTesting(
            connectSymbol: "__ZN6WebKit26WebPageInspectorController27definitelyMissingConnectFooEv",
            disconnectSymbol: "__ZN6WebKit26WebPageInspectorController30definitelyMissingDisconnectBarEv"
        )

        XCTAssertNotNil(resolution.failureReason)
        XCTAssertEqual(resolution.connectFrontendAddress, 0)
        XCTAssertEqual(resolution.disconnectFrontendAddress, 0)
    }
}
#endif
