#if canImport(UIKit)
import UIKit
#endif
import WebInspectorDataKit
import WebInspectorUIBase

@MainActor
package enum NetworkPreviewFixtures {
    package enum Mode {
        case root
        case rootLongTitle
        case detail
        case detailResponseOnlyShort
        case detailRequestAndResponseShort
        case detailResponseOnlyLong
        case detailRequestAndResponseLong
    }

    package static func makePanelModel(mode: Mode) async throws -> NetworkPanelModel {
        let context = makeContext(mode: mode)
        let model = try await NetworkPanelModel.make(context: context)
        switch mode {
        case .detail,
             .detailResponseOnlyShort,
             .detailRequestAndResponseShort,
             .detailResponseOnlyLong,
             .detailRequestAndResponseLong:
            model.selectEntry(model.entries.snapshot.itemIDs.first)
        case .root, .rootLongTitle:
            break
        }
        return model
    }

    #if canImport(UIKit)
    package static func makeViewController(
        mode: Mode,
        makeReadyViewController: @escaping @MainActor (NetworkPanelModel) -> UIViewController
    ) -> UIViewController {
        NetworkPreviewResourceViewController(
            mode: mode,
            makeReadyViewController: makeReadyViewController
        )
    }
    #endif

    package static func makeContext(mode: Mode) -> WebInspectorModelContext {
        let context = WebInspectorModelContext.preview()
        applySampleData(to: context, mode: mode)
        return context
    }

    package static func applySampleData(to context: WebInspectorModelContext, mode: Mode) {
        switch mode {
        case .detailResponseOnlyShort:
            applyRequest(
                to: context,
                requestID: "1001",
                url: "https://api.example.com/v1/status.json",
                method: "GET",
                resourceTypeRawValue: "XHR",
                responseMimeType: "application/json",
                status: 200,
                statusText: "OK",
                timestamp: 1.0,
                encodedBodyLength: 64,
                responseBody: shortPreviewJSONBody(kind: "response-only")
            )
            return
        case .detailRequestAndResponseShort:
            applyRequest(
                to: context,
                requestID: "1001",
                url: "https://telemetry.example/log.json",
                method: "POST",
                resourceTypeRawValue: "XHR",
                responseMimeType: "application/json",
                status: 200,
                statusText: "OK",
                timestamp: 1.0,
                encodedBodyLength: 64,
                requestHeaders: ["content-type": "application/json"],
                postData: shortPreviewJSONBody(kind: "request"),
                responseBody: shortPreviewJSONBody(kind: "response")
            )
            return
        case .detailResponseOnlyLong:
            applyRequest(
                to: context,
                requestID: "1001",
                url: "https://api.example.com/v1/status.json",
                method: "GET",
                resourceTypeRawValue: "XHR",
                responseMimeType: "application/json",
                status: 200,
                statusText: "OK",
                timestamp: 1.0,
                encodedBodyLength: 1_024,
                responseBody: longPreviewJSONBody(kind: "response-only")
            )
            return
        case .detailRequestAndResponseLong:
            applyRequest(
                to: context,
                requestID: "1001",
                url: "https://telemetry.example/log.json",
                method: "POST",
                resourceTypeRawValue: "XHR",
                responseMimeType: "application/json",
                status: 200,
                statusText: "OK",
                timestamp: 1.0,
                encodedBodyLength: 1_024,
                requestHeaders: ["content-type": "application/json"],
                postData: longPreviewJSONBody(kind: "request"),
                responseBody: longPreviewJSONBody(kind: "response")
            )
            return
        case .root, .rootLongTitle, .detail:
            break
        }

        applyRequest(
            to: context,
            requestID: "1001",
            url: "https://telemetry.example/log",
            method: "POST",
            resourceTypeRawValue: "XHR",
            responseMimeType: "application/json",
            status: 200,
            statusText: "OK",
            timestamp: 1.0,
            encodedBodyLength: 64
        )
        applyRequest(
            to: context,
            requestID: "1002",
            url: "https://static.example/images/icons/trending-up.png",
            resourceTypeRawValue: "Image",
            responseMimeType: "image/png",
            status: 200,
            statusText: "OK",
            timestamp: 0.9,
            encodedBodyLength: 0
        )

        if mode == .rootLongTitle {
            applyRequest(
                to: context,
                requestID: "1999",
                url: "https://cdn.example.com/assets/network/preview/super-long-file-name-for-line-wrap-validation-with-json-tag-rendering-and-truncation-check.json",
                resourceTypeRawValue: "XHR",
                responseMimeType: "application/json",
                status: 200,
                statusText: "OK",
                timestamp: 1.9,
                encodedBodyLength: 512
            )
        }
    }

    @discardableResult
    private static func applyRequest(
        to context: WebInspectorModelContext,
        requestID: String,
        url: String,
        method: String = "GET",
        resourceTypeRawValue: String,
        responseMimeType: String,
        status: Int,
        statusText: String,
        timestamp: Double,
        encodedBodyLength: Int,
        requestHeaders: [String: String]? = nil,
        postData: String? = nil,
        responseBody: String? = nil
    ) -> NetworkRequest.ID {
        let resolvedPostData = postData ?? (method == "POST" ? "sample=true&source=wi-preview" : nil)
        let resolvedRequestHeaders = requestHeaders
            ?? (resolvedPostData == nil ? [:] : ["content-type": "application/x-www-form-urlencoded"])
        return context.seedNetworkRequest(
            requestID: requestID,
            url: url,
            method: method,
            resourceTypeRawValue: resourceTypeRawValue,
            requestHeaders: resolvedRequestHeaders,
            postData: resolvedPostData,
            responseMIMEType: responseMimeType,
            responseStatus: status,
            responseStatusText: statusText,
            responseHeaders: [
                "content-length": String(encodedBodyLength),
                "content-type": responseMimeType,
            ],
            responseBody: responseMimeType == "application/json"
                ? (responseBody ?? #"{"result":"ok","items":[1,2,3],"source":"preview"}"#)
                : nil,
            timestamp: timestamp,
            encodedBodyLength: encodedBodyLength
        )
    }

    private static func shortPreviewJSONBody(kind: String) -> String {
        #"{"kind":"\#(kind)","result":"ok","source":"preview"}"#
    }

    private static func longPreviewJSONBody(kind: String) -> String {
        let items = (1...24).map { index in
            let enabled = index.isMultiple(of: 2) ? "true" : "false"
            return #"{"id":\#(index),"name":"\#(kind)-item-\#(index)","enabled":\#(enabled)}"#
        }.joined(separator: ",")
        return #"{"kind":"\#(kind)","result":"ok","items":[\#(items)],"metadata":{"source":"preview","count":24}}"#
    }
}

#if canImport(UIKit)
@MainActor
private final class NetworkPreviewResourceViewController: UIViewController {
    private var loadTask: Task<Void, Never>?

    init(
        mode: NetworkPreviewFixtures.Mode,
        makeReadyViewController: @escaping @MainActor (NetworkPanelModel) -> UIViewController
    ) {
        super.init(nibName: nil, bundle: nil)
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        loadTask = Task { @MainActor [weak self] in
            do {
                let model = try await NetworkPreviewFixtures.makePanelModel(mode: mode)
                guard let self, Task.isCancelled == false else {
                    await model.retire()
                    return
                }
                install(makeReadyViewController(model))
                loadTask = nil
            } catch {
                guard let self else {
                    return
                }
                var configuration = UIContentUnavailableConfiguration.empty()
                configuration.text = "Network Preview Unavailable"
                configuration.secondaryText = error.localizedDescription
                contentUnavailableConfiguration = configuration
                loadTask = nil
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        loadTask?.cancel()
    }

    private func install(_ viewController: UIViewController) {
        contentUnavailableConfiguration = nil
        addChild(viewController)
        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(viewController.view)
        NSLayoutConstraint.activate([
            viewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            viewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            viewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            viewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        viewController.didMove(toParent: self)
    }
}
#endif
