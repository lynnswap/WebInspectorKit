import Foundation
import Testing
@testable import WebInspectorUI
@testable import WebInspectorEngine
@testable import WebInspectorRuntime

@MainActor
struct NetworkBodyPreviewRenderModelTests {
    @Test
    func jsonBodyEnablesObjectTreeAndPrefersObjectTreeMode() {
        let body = NetworkBody(
            kind: .text,
            preview: nil,
            full: "{\"data\":{\"value\":1}}",
            size: nil,
            isBase64Encoded: false,
            isTruncated: false,
            summary: nil,
            reference: nil,
            formEntries: [],
            fetchState: .full,
            role: .response
        )

        let model = NetworkBodyPreviewRenderModel.make(
            from: .init(body: body, unavailableText: "Body unavailable")
        )

        #expect(model.availableModes == [.text, .objectTree])
        #expect(model.preferredMode == .objectTree)
        #expect(!model.objectTreeNodes.isEmpty)
    }

    @Test
    func textModePrettyPrintsJSONWhenFormattingIsPossible() {
        let compactJSON = "{\"name\":\"codex\",\"value\":42}"
        let body = NetworkBody(
            kind: .text,
            preview: nil,
            full: compactJSON,
            size: nil,
            isBase64Encoded: false,
            isTruncated: false,
            summary: nil,
            reference: nil,
            formEntries: [],
            fetchState: .full,
            role: .response
        )

        let model = NetworkBodyPreviewRenderModel.make(
            from: .init(body: body, unavailableText: "Body unavailable")
        )

        #expect(model.text != compactJSON)
        #expect(model.text.contains("\n"))
        #expect(model.text.contains("\"name\""))
    }

    @Test
    func nonJSONBodyKeepsTextModeOnlyAndRawText() {
        let raw = "plain text response"
        let body = NetworkBody(
            kind: .text,
            preview: raw,
            full: nil,
            size: nil,
            isBase64Encoded: false,
            isTruncated: false,
            summary: nil,
            reference: nil,
            formEntries: [],
            fetchState: .full,
            role: .response
        )

        let model = NetworkBodyPreviewRenderModel.make(
            from: .init(body: body, unavailableText: "Body unavailable")
        )

        #expect(model.availableModes == [.text])
        #expect(model.preferredMode == .text)
        #expect(model.objectTreeNodes.isEmpty)
        #expect(model.text == raw)
    }

    @Test
    func summaryOnlyBodyDoesNotEnableObjectTree() {
        let summary = "0"
        let body = NetworkBody(
            kind: .text,
            preview: nil,
            full: nil,
            size: nil,
            isBase64Encoded: false,
            isTruncated: true,
            summary: summary,
            reference: "resp_ref",
            formEntries: [],
            fetchState: .inline,
            role: .response
        )

        let model = NetworkBodyPreviewRenderModel.make(
            from: .init(body: body, unavailableText: "Body unavailable")
        )

        #expect(model.availableModes == [.text])
        #expect(model.objectTreeNodes.isEmpty)
        #expect(model.text == summary)
    }

    @Test
    func failedFetchDisplayTextFallsBackAndAppendsError() {
        let body = NetworkBody(
            kind: .text,
            preview: nil,
            full: nil,
            size: nil,
            isBase64Encoded: false,
            isTruncated: true,
            summary: nil,
            reference: "resp_ref",
            formEntries: [],
            fetchState: .inline,
            role: .response
        )

        let unavailableText = "Body unavailable"
        let model = NetworkBodyPreviewRenderModel.make(
            from: .init(body: body, unavailableText: unavailableText)
        )
        let displayText = model.displayText(
            for: .failed(.decodeFailed),
            fetchingText: "Fetching body...",
            unavailableText: unavailableText
        )

        #expect(displayText.contains(unavailableText))
        #expect(displayText.contains(NetworkBody.FetchError.decodeFailed.localizedDescriptionText))
    }

    @Test
    func staleGenerationIsRejectedAfterNewGenerationArrives() {
        let generation = NetworkBodyPreviewRenderGeneration()
        let first = generation.advance()
        let second = generation.advance()

        #expect(first != second)
        #expect(generation.shouldApply(first) == false)
        #expect(generation.shouldApply(second))
    }
}
