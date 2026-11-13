import Foundation
import Observation
import ObservationBridge
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

@MainActor
@Test
func elementPickerInspectBeforeEnableContinuationCannotReactivatePicker() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let documentID = DOM.Node.ID("picker-race-document")
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
    )
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")

    let enableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )

    await runtime.backend.emit(.inspect(documentID), target: target)
    try await waitUntil(in: context) { context.selectedNode?.id == DOMNode.ID(documentID) }
    #expect(context.isElementPickerEnabled == false)

    await enableGate.open()
    try await enableTask.value

    #expect(context.isElementPickerEnabled == false)
}

@MainActor
@Test
func overlappingElementPickerEnableAndDisableLinearizeLatestIntent() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")

    let enableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )

    let disableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(false)
    }
    await enableGate.open()

    try await enableTask.value
    try await disableTask.value

    let commands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(commands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true, false])
    #expect(context.isElementPickerEnabled == false)
}

@MainActor
@Test
func unavailableElementPickerRequestDoesNotChangeNextToggleIntent() async throws {
    let context = WebInspectorContext.preview()
    let unavailableError = WebInspectorProxyError.disconnected(
        "WebInspectorDataKit has no current page target."
    )

    await #expect(throws: unavailableError) {
        try await context.setElementPickerEnabled(true)
    }
    await #expect(throws: unavailableError) {
        try await context.toggleElementPickerEnabled()
    }

    #expect(context.requestedElementPickerEnabledForTesting == nil)
    #expect(context.isElementPickerEnabled == false)
}

@MainActor
@Test
func rapidElementPickerTogglesFlipPendingIntent() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")

    let enableTask = Task { @MainActor in
        try await context.toggleElementPickerEnabled()
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )
    let disableTask = Task { @MainActor in
        try await context.toggleElementPickerEnabled()
    }
    try await waitUntil(in: context) {
        context.requestedElementPickerEnabledForTesting == false
    }
    await enableGate.open()

    try await enableTask.value
    try await disableTask.value

    let commands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(commands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true, false])
    #expect(context.isElementPickerEnabled == false)
}

@MainActor
@Test
func rapidElementPickerEnableDisableEnableAppliesOnlyLatestIntent() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")

    let firstEnableTask = Task { @MainActor in
        try await context.toggleElementPickerEnabled()
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )
    let disableTask = Task { @MainActor in
        try await context.toggleElementPickerEnabled()
    }
    try await waitUntil(in: context) {
        context.requestedElementPickerEnabledForTesting == false
    }
    let latestEnableTask = Task { @MainActor in
        try await context.toggleElementPickerEnabled()
    }
    try await waitUntil(in: context) {
        context.requestedElementPickerEnabledForTesting == true
    }
    await enableGate.open()

    try await firstEnableTask.value
    try await disableTask.value
    try await latestEnableTask.value

    let commands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(commands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true])
    #expect(context.isElementPickerEnabled)
}

@MainActor
@Test
func coalescedElementPickerCallersShareFailureWithoutRetry() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let enableGate = WebInspectorTestGate()
    let enableError = WebInspectorProxyError.commandFailed(
        domain: "DOM",
        method: "setInspectModeEnabled",
        message: "enable failed"
    )

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueueFailure(
        enableError,
        for: "DOM",
        method: "setInspectModeEnabled"
    )

    let firstEnableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )
    var stateChanges = context.stateChangeStreamForTesting().makeAsyncIterator()
    let latestEnableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    // The second caller records its request before it waits for the command.
    _ = await stateChanges.next()
    await enableGate.open()

    await #expect(throws: enableError) {
        try await firstEnableTask.value
    }
    await #expect(throws: enableError) {
        try await latestEnableTask.value
    }

    let commands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(commands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true])
    #expect(context.isElementPickerEnabled == false)

    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    try await context.setElementPickerEnabled(true)

    let recoveredCommands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(recoveredCommands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true, true])
    #expect(context.isElementPickerEnabled)
}

@MainActor
@Test
func failedElementPickerEnableDoesNotFailPendingDisable() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let enableGate = WebInspectorTestGate()
    let enableError = WebInspectorProxyError.commandFailed(
        domain: "DOM",
        method: "setInspectModeEnabled",
        message: "enable failed"
    )

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueueFailure(enableError, for: "DOM", method: "setInspectModeEnabled")

    let enableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )
    let disableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(false)
    }
    try await waitUntil(in: context) {
        context.requestedElementPickerEnabledForTesting == false
    }
    await enableGate.open()

    await #expect(throws: enableError) {
        try await enableTask.value
    }
    try await disableTask.value

    let commands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(commands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true])
    #expect(context.isElementPickerEnabled == false)
}

@MainActor
@Test
func elementPickerInspectBeforeFailedEnableReplySettlesWithoutError() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let documentID = DOM.Node.ID("picker-inspect-failure-document")
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: documentID, nodeType: 9, nodeName: "#document")
    )
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueueFailure(
        WebInspectorProxyError.commandFailed(
            domain: "DOM",
            method: "setInspectModeEnabled",
            message: "enable reply lost"
        ),
        for: "DOM",
        method: "setInspectModeEnabled"
    )

    let enableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )

    await runtime.backend.emit(.inspect(documentID), target: target)
    try await waitUntil(in: context) { context.selectedNode?.id == DOMNode.ID(documentID) }

    await enableGate.open()
    try await enableTask.value

    #expect(context.isElementPickerEnabled == false)
}

@MainActor
@Test
func cancellingElementPickerCallerDoesNotRevertRequest() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")

    let enableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )

    enableTask.cancel()
    await enableGate.open()
    try await enableTask.value

    let commands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(commands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true])
    #expect(context.isElementPickerEnabled)
}

@MainActor
@Test
func elementPickerEnableReplyFromPreviousDocumentCannotApply() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: DOM.Node.ID("picker-old-document"), nodeType: 9, nodeName: "#document")
    )
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")

    let enableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )

    let newDocumentID = DOM.Node.ID("picker-new-document")
    await runtime.backend.enqueue(
        DOM.Node(id: newDocumentID, nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await runtime.backend.emit(
        .frameNavigated(WebInspectorPageFrameLifecycle(
            id: FrameID("main-frame"),
            parentID: nil,
            loaderID: "picker-new-loader",
            name: "Main",
            url: "https://example.test/picker-new-document",
            securityOrigin: "https://example.test",
            mimeType: "text/html"
        )),
        target: target
    )
    try await waitUntil(in: context) { context.rootNode?.id == DOMNode.ID(newDocumentID) }

    await enableGate.open()
    await #expect(
        throws: WebInspectorProxyError.disconnected(
            "DOM element picker operation no longer belongs to the current document."
        )
    ) {
        try await enableTask.value
    }

    #expect(context.rootNode?.id == DOMNode.ID(newDocumentID))
    #expect(context.isElementPickerEnabled == false)
    let pickerCommands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(pickerCommands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true, false])
}

@MainActor
@Test
func failedStalePickerCleanupDoesNotReactivateReplacementDocument() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(
        runtime: runtime,
        document: DOM.Node(id: DOM.Node.ID("picker-stale-document"), nodeType: 9, nodeName: "#document")
    )
    let enableGate = WebInspectorTestGate()
    let rollbackError = WebInspectorProxyError.commandFailed(
        domain: "DOM",
        method: "setInspectModeEnabled",
        message: "stale rollback failed"
    )

    await runtime.backend.hold(domain: "DOM", method: "setInspectModeEnabled", gate: enableGate)
    await runtime.backend.enqueue((), for: "DOM", method: "setInspectModeEnabled")
    await runtime.backend.enqueueFailure(
        rollbackError,
        for: "DOM",
        method: "setInspectModeEnabled"
    )

    let enableTask = Task { @MainActor in
        try await context.setElementPickerEnabled(true)
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "DOM",
        method: "setInspectModeEnabled",
        count: 1
    )

    let replacementDocumentID = DOM.Node.ID("picker-replacement-document")
    await runtime.backend.enqueue(
        DOM.Node(id: replacementDocumentID, nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await runtime.backend.emit(
        .frameNavigated(WebInspectorPageFrameLifecycle(
            id: FrameID("main-frame"),
            parentID: nil,
            loaderID: "picker-replacement-loader",
            name: "Main",
            url: "https://example.test/picker-replacement-document",
            securityOrigin: "https://example.test",
            mimeType: "text/html"
        )),
        target: target
    )
    try await waitUntil(in: context) {
        context.rootNode?.id == DOMNode.ID(replacementDocumentID)
    }

    await enableGate.open()
    await #expect(throws: rollbackError) {
        try await enableTask.value
    }

    #expect(context.rootNode?.id == DOMNode.ID(replacementDocumentID))
    #expect(context.isElementPickerEnabled == false)
    let pickerCommands = await runtime.backend.recordedCommands().filter {
        $0.domain == "DOM" && $0.method == "setInspectModeEnabled"
    }
    #expect(pickerCommands.compactMap {
        $0.payload.cast(as: DOM.SetInspectModeEnabledPayload.self)?.enabled
    } == [true, false])
}
