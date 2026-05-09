#if DEBUG
import Foundation
import WebInspectorEngine
import WebInspectorRuntime

@MainActor
enum WINetworkPreviewFixtures {
    enum Mode {
        case root
        case rootLongTitle
        case detail
        case bodyPreviewObjectTree
        case bodyPreviewText
    }

    static func makeInspector(mode: Mode) -> WINetworkModel {
        let session = NetworkSession()
        let inspector = WINetworkModel(session: session)
        applySampleData(to: inspector, mode: mode)
        return inspector
    }

    static func applySampleData(to inspector: WINetworkModel, mode: Mode) {
        let snapshots: [NetworkEntry.Snapshot]
        switch mode {
        case .root:
            snapshots = sampleSnapshots()
        case .rootLongTitle:
            snapshots = sampleSnapshots(includeLongTitle: true)
        case .detail:
            snapshots = sampleSnapshots()
        case .bodyPreviewObjectTree:
            snapshots = sampleSnapshots(bodyMode: .json)
        case .bodyPreviewText:
            snapshots = sampleSnapshots(bodyMode: .plainText)
        }

        inspector.store.applySnapshots(snapshots)
        switch mode {
        case .detail, .bodyPreviewObjectTree, .bodyPreviewText:
            inspector.selectEntry(preferredDetailEntry(in: inspector))
        case .root, .rootLongTitle:
            inspector.selectEntry(nil)
        }
    }

    static func makeDetailContext() -> (inspector: WINetworkModel, entry: NetworkEntry)? {
        let inspector = makeInspector(mode: .detail)
        guard let entry = preferredDetailEntry(in: inspector) else {
            return nil
        }
        inspector.selectEntry(entry)
        return (inspector, entry)
    }

    static func makeBodyPreviewContext(textMode: Bool = false) -> (inspector: WINetworkModel, entry: NetworkEntry, body: NetworkBody)? {
        let inspector = makeInspector(mode: textMode ? .bodyPreviewText : .bodyPreviewObjectTree)
        guard
            let entry = preferredDetailEntry(in: inspector),
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

    private static func sampleSnapshots(
        includeLongTitle: Bool = false,
        bodyMode: BodyMode = .json
    ) -> [NetworkEntry.Snapshot] {
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

        var snapshots: [NetworkEntry.Snapshot] = [
            makeSnapshot(
                requestID: 1001,
                url: "https://play.google.com/log?format=json&hasfast=true",
                method: "POST",
                requestHeaders: NetworkHeaders(dictionary: [
                    "authorization": "Bearer preview-token",
                    "content-type": "application/x-www-form-urlencoded",
                ]),
                requestBody: NetworkBody(
                    kind: .text,
                    preview: "hl=ja&gl=JP&source=wi-preview",
                    full: "hl=ja&gl=JP&source=wi-preview",
                    size: 64,
                    isTruncated: false,
                    role: .request
                ),
                requestBodyBytesSent: 64,
                responseMimeType: mimeType,
                responseHeaders: NetworkHeaders(dictionary: [
                    "content-length": String(bodyText.count),
                    "content-type": contentType,
                ]),
                responseBody: NetworkBody(
                    kind: .text,
                    preview: bodyText,
                    full: bodyText,
                    size: bodyText.count,
                    isTruncated: false,
                    role: .response
                ),
                statusCode: 200,
                statusText: "OK",
                startTimestamp: 1.0,
                endTimestamp: 1.125,
                wallTime: 1_700_000_000.0,
                encodedBodyLength: bodyText.count,
                decodedBodyLength: bodyText.count,
                type: "xhr"
            ),
            makeSnapshot(
                requestID: 1002,
                url: "https://www.gstatic.com/images/icons/material/system/2x/trending_up_grey600_24dp.png",
                responseMimeType: "image/png",
                statusCode: 200,
                statusText: "OK",
                startTimestamp: 0.9,
                endTimestamp: 1.728,
                wallTime: 1_699_999_999.4,
                encodedBodyLength: 0,
                decodedBodyLength: 0,
                type: "img"
            ),
        ]

        if includeLongTitle {
            snapshots.insert(
                makeSnapshot(
                    requestID: 1999,
                    url: "https://cdn.example.com/assets/network/preview/super-long-file-name-for-line-wrap-validation-with-json-tag-rendering-and-truncation-check.json",
                    responseMimeType: "application/json",
                    statusCode: 200,
                    statusText: "OK",
                    startTimestamp: 1.9,
                    endTimestamp: 2.2,
                    wallTime: 1_700_000_000.8,
                    encodedBodyLength: 512,
                    decodedBodyLength: 512,
                    type: "xhr"
                ),
                at: 0
            )
        }

        return snapshots
    }

    private static func makeSnapshot(
        requestID: Int,
        url: String,
        method: String = "GET",
        requestHeaders: NetworkHeaders = NetworkHeaders(),
        requestBody: NetworkBody? = nil,
        requestBodyBytesSent: Int? = nil,
        responseMimeType: String? = nil,
        responseHeaders: NetworkHeaders = NetworkHeaders(),
        responseBody: NetworkBody? = nil,
        statusCode: Int? = nil,
        statusText: String = "",
        startTimestamp: TimeInterval,
        endTimestamp: TimeInterval?,
        wallTime: TimeInterval?,
        encodedBodyLength: Int?,
        decodedBodyLength: Int?,
        type: String?
    ) -> NetworkEntry.Snapshot {
        NetworkEntry.Snapshot(
            sessionID: "preview-session",
            requestID: requestID,
            request: NetworkEntry.Request(
                url: url,
                method: method,
                headers: requestHeaders,
                body: requestBody,
                bodyBytesSent: requestBodyBytesSent,
                type: type,
                wallTime: wallTime
            ),
            response: NetworkEntry.Response(
                statusCode: statusCode,
                statusText: statusText,
                mimeType: responseMimeType,
                headers: responseHeaders,
                body: responseBody,
                blockedCookies: [],
                errorDescription: nil
            ),
            transfer: NetworkEntry.Transfer(
                startTimestamp: startTimestamp,
                endTimestamp: endTimestamp,
                duration: endTimestamp.map { $0 - startTimestamp },
                encodedBodyLength: encodedBodyLength,
                decodedBodyLength: decodedBodyLength,
                phase: .completed
            )
        )
    }

    private static func preferredDetailEntry(in inspector: WINetworkModel) -> NetworkEntry? {
        inspector.displayEntries.first(where: {
            $0.responseBody != nil || $0.requestBody != nil
        }) ?? inspector.displayEntries.first
    }
}
#endif
