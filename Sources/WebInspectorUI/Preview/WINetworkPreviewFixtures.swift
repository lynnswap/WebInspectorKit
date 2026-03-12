#if DEBUG
import Foundation
@_spi(PreviewSupport) import WebInspectorCore
@_spi(PreviewSupport) import WebInspectorNetwork

@MainActor
enum WINetworkPreviewFixtures {
    enum Mode {
        case root
        case rootLongTitle
        case detail
        case bodyPreviewObjectTree
        case bodyPreviewText
    }

    static func makeInspector(mode: Mode) -> WINetworkInspectorStore {
        let session = NetworkSession()
        let inspector = WINetworkInspectorStore(session: session)
        applySampleData(to: inspector, mode: mode)
        return inspector
    }

    static func applySampleData(to inspector: WINetworkInspectorStore, mode: Mode) {
        let queryState = WINetworkQueryState(inspector: inspector)
        let payload: NSDictionary
        switch mode {
        case .root:
            payload = sampleBatchPayload()
        case .rootLongTitle:
            payload = sampleBatchPayload(includeLongTitle: true)
        case .detail:
            payload = sampleBatchPayload()
        case .bodyPreviewObjectTree:
            payload = sampleBatchPayload(bodyMode: .json)
        case .bodyPreviewText:
            payload = sampleBatchPayload(bodyMode: .plainText)
        }

        inspector.wiApplyPreviewBatch(payload)
        switch mode {
        case .detail, .bodyPreviewObjectTree, .bodyPreviewText:
            inspector.selectEntry(queryState.displayEntries.first)
        case .root, .rootLongTitle:
            inspector.selectEntry(nil)
        }
    }

    static func makeDetailContext() -> (inspector: WINetworkInspectorStore, entry: NetworkEntry)? {
        let inspector = makeInspector(mode: .detail)
        let queryState = WINetworkQueryState(inspector: inspector)
        guard let entry = queryState.displayEntries.first else {
            return nil
        }
        inspector.selectEntry(entry)
        return (inspector, entry)
    }

    static func makeBodyPreviewContext(textMode: Bool = false) -> (inspector: WINetworkInspectorStore, entry: NetworkEntry, body: NetworkBody)? {
        let inspector = makeInspector(mode: textMode ? .bodyPreviewText : .bodyPreviewObjectTree)
        let queryState = WINetworkQueryState(inspector: inspector)
        guard
            let entry = queryState.displayEntries.first,
            let body = entry.responseBody ?? entry.requestBody
        else {
            return nil
        }
        inspector.selectEntry(entry)
        return (inspector, entry, body)
    }

    private enum BodyMode {
        case json
        case plainText
    }

    private static func sampleBatchPayload(
        includeLongTitle: Bool = false,
        bodyMode: BodyMode = .json
    ) -> NSDictionary {
        let bodyText: String
        let mimeType: String
        let contentType: String

        switch bodyMode {
        case .json:
            bodyText = "{\"result\":\"ok\",\"items\":[1,2,3],\"meta\":{\"source\":\"preview\"}}"
            mimeType = "application/json"
            contentType = "application/json; charset=utf-8"
        case .plainText:
            bodyText = "status=ok; source=preview; mode=text"
            mimeType = "text/plain"
            contentType = "text/plain; charset=utf-8"
        }

        var events: [[String: Any]] = [
            [
                "kind": "requestWillBeSent",
                "requestId": 1001,
                "time": ["monotonicMs": 1000.0, "wallMs": 1700000000000.0],
                "url": "https://play.google.com/log?format=json&hasfast=true",
                "method": "POST",
                "headers": [
                    "authorization": "Bearer preview-token",
                    "content-type": "application/x-www-form-urlencoded"
                ],
                "body": [
                    "kind": "text",
                    "size": 64,
                    "truncated": false,
                    "preview": "hl=ja&gl=JP&source=wi-preview"
                ],
                "bodySize": 64,
                "initiator": "xhr"
            ],
            [
                "kind": "responseReceived",
                "requestId": 1001,
                "time": ["monotonicMs": 1119.0, "wallMs": 1700000000119.0],
                "status": 200,
                "statusText": "OK",
                "mimeType": mimeType,
                "headers": [
                    "content-length": String(bodyText.count),
                    "content-type": contentType
                ],
                "initiator": "xhr"
            ],
            [
                "kind": "loadingFinished",
                "requestId": 1001,
                "time": ["monotonicMs": 1125.0, "wallMs": 1700000000125.0],
                "encodedBodyLength": bodyText.count,
                "decodedBodySize": bodyText.count,
                "body": [
                    "kind": "text",
                    "size": bodyText.count,
                    "truncated": false,
                    "preview": bodyText,
                    "content": bodyText
                ],
                "initiator": "xhr"
            ],
            [
                "kind": "resourceTiming",
                "requestId": 1002,
                "url": "https://www.gstatic.com/images/icons/material/system/2x/trending_up_grey600_24dp.png",
                "method": "GET",
                "status": 200,
                "statusText": "OK",
                "mimeType": "image/png",
                "startTime": ["monotonicMs": 900.0, "wallMs": 1699999999400.0],
                "endTime": ["monotonicMs": 1728.0, "wallMs": 1700000000228.0],
                "encodedBodyLength": 0,
                "decodedBodySize": 0,
                "initiator": "img"
            ]
        ]

        if includeLongTitle {
            events.insert(
                [
                    "kind": "resourceTiming",
                    "requestId": 1999,
                    "url": "https://cdn.example.com/assets/network/preview/super-long-file-name-for-line-wrap-validation-with-json-tag-rendering-and-truncation-check.json",
                    "method": "GET",
                    "status": 200,
                    "statusText": "OK",
                    "mimeType": "application/json",
                    "startTime": ["monotonicMs": 1900.0, "wallMs": 1700000000800.0],
                    "endTime": ["monotonicMs": 2200.0, "wallMs": 1700000001100.0],
                    "encodedBodyLength": 512,
                    "decodedBodySize": 512,
                    "initiator": "xhr"
                ],
                at: 0
            )
        }

        return [
            "version": 1,
            "sessionId": "preview-session",
            "seq": 1,
            "events": events
        ]
    }
}
#endif
