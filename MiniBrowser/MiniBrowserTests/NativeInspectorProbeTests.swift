import XCTest
@testable import MiniBrowser

final class NativeInspectorProbeTests: XCTestCase {
    func testProbeResultIsTerminalForSucceededStatus() {
        let result = NativeInspectorProbeResult(
            status: .succeeded,
            stage: "body fetch",
            message: "done",
            urlString: "https://example.com/",
            requestIdentifier: "request-1",
            bodyPreview: "<html></html>",
            base64Encoded: false,
            rawBackendError: nil,
            rawMessage: nil
        )

        XCTAssertTrue(result.isTerminal)
    }

    func testProbeResultIsNotTerminalWhileRunning() {
        let result = NativeInspectorProbeResult(
            status: .running,
            stage: "attach",
            message: "loading",
            urlString: "https://example.com/",
            requestIdentifier: nil,
            bodyPreview: nil,
            base64Encoded: false,
            rawBackendError: nil,
            rawMessage: nil
        )

        XCTAssertFalse(result.isTerminal)
    }
}
