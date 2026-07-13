#if canImport(UIKit)
import UIKit
import WebInspectorDataKit
import WebInspectorDataKitTesting
import WebInspectorProxyKit
import WebInspectorUINetwork
import WebInspectorUISyntaxBody

@MainActor
private enum NetworkPreviewFixtures {
    enum Mode {
        case root
        case rootLongTitle
        case detail
        case detailResponseOnlyShort
        case detailRequestAndResponseShort
        case detailResponseOnlyLong
        case detailRequestAndResponseLong
    }

    static func makeViewController(
        mode: Mode,
        makeReadyViewController:
            @escaping @MainActor (NetworkPanelModel) -> UIViewController
    ) -> UIViewController {
        NetworkPreviewResourceViewController(
            mode: mode,
            makeReadyViewController: makeReadyViewController
        )
    }

    static func start(mode: Mode) async throws
        -> (WebInspectorDataKitTestRuntime, NetworkPanelModel)
    {
        let runtime = try await WebInspectorDataKitTestRuntime.start(
            scenario: scenario(mode: mode),
            isolation: MainActor.shared
        )
        do {
            let model = try await NetworkPanelModel.make(
                context: runtime.model
            )
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
            return (runtime, model)
        } catch {
            await runtime.close()
            throw error
        }
    }

    private static func scenario(
        mode: Mode
    ) -> WebInspectorDataKitTestRuntime.Scenario {
        .init(
            configuration: .init(domains: [.network]),
            networkReplay: requests(mode: mode)
        )
    }

    private static func requests(
        mode: Mode
    ) -> [WebInspectorDataKitTestRuntime.NetworkRequest] {
        switch mode {
        case .detailResponseOnlyShort:
            return [jsonRequest(
                id: "1001",
                url: "https://api.example.com/v1/status.json",
                responseBody: shortJSON(kind: "response-only")
            )]
        case .detailRequestAndResponseShort:
            return [jsonRequest(
                id: "1001",
                url: "https://telemetry.example/log.json",
                method: "POST",
                postData: shortJSON(kind: "request"),
                responseBody: shortJSON(kind: "response")
            )]
        case .detailResponseOnlyLong:
            return [jsonRequest(
                id: "1001",
                url: "https://api.example.com/v1/status.json",
                encodedDataLength: 1_024,
                responseBody: longJSON(kind: "response-only")
            )]
        case .detailRequestAndResponseLong:
            return [jsonRequest(
                id: "1001",
                url: "https://telemetry.example/log.json",
                method: "POST",
                postData: longJSON(kind: "request"),
                encodedDataLength: 1_024,
                responseBody: longJSON(kind: "response")
            )]
        case .root, .detail:
            return standardRequests
        case .rootLongTitle:
            return standardRequests + [jsonRequest(
                id: "1999",
                url: "https://cdn.example.com/assets/network/preview/super-long-file-name-for-line-wrap-validation-with-json-tag-rendering-and-truncation-check.json",
                encodedDataLength: 512
            )]
        }
    }

    private static var standardRequests:
        [WebInspectorDataKitTestRuntime.NetworkRequest]
    {
        [
            jsonRequest(
                id: "1001",
                url: "https://telemetry.example/log",
                method: "POST",
                postData: "sample=true&source=wi-preview"
            ),
            .init(
                id: "1002",
                url: "https://static.example/images/icons/trending-up.png",
                statusText: "OK",
                responseHeaders: ["content-type": "image/png"],
                mimeType: "image/png",
                resourceType: .image,
                encodedDataLength: 0
            ),
        ]
    }

    private static func jsonRequest(
        id: String,
        url: String,
        method: String = "GET",
        postData: String? = nil,
        encodedDataLength: Int = 64,
        responseBody: String = #"{"result":"ok","items":[1,2,3],"source":"preview"}"#
    ) -> WebInspectorDataKitTestRuntime.NetworkRequest {
        let requestContentType = postData == nil
            ? [:]
            : ["content-type": "application/json"]
        return .init(
            id: id,
            url: url,
            method: method,
            requestHeaders: requestContentType,
            postData: postData,
            statusText: "OK",
            responseHeaders: [
                "content-length": String(encodedDataLength),
                "content-type": "application/json",
            ],
            mimeType: "application/json",
            resourceType: .xhr,
            encodedDataLength: encodedDataLength,
            body: Network.Body(data: responseBody)
        )
    }

    private static func shortJSON(kind: String) -> String {
        #"{"kind":"\#(kind)","result":"ok","source":"preview"}"#
    }

    private static func longJSON(kind: String) -> String {
        let items = (1...24).map { index in
            let enabled = index.isMultiple(of: 2) ? "true" : "false"
            return #"{"id":\#(index),"name":"\#(kind)-item-\#(index)","enabled":\#(enabled)}"#
        }.joined(separator: ",")
        return #"{"kind":"\#(kind)","result":"ok","items":[\#(items)],"metadata":{"source":"preview","count":24}}"#
    }
}

@MainActor
private final class NetworkPreviewResourceViewController: UIViewController {
    private let mode: NetworkPreviewFixtures.Mode
    private let makeReadyViewController:
        @MainActor (NetworkPanelModel) -> UIViewController
    private var loadTask: Task<Void, Never>?
    private var retirementTask: Task<Void, Never>?
    private var runtime: WebInspectorDataKitTestRuntime?
    private var model: NetworkPanelModel?
    private var isRetired = false

    init(
        mode: NetworkPreviewFixtures.Mode,
        makeReadyViewController:
            @escaping @MainActor (NetworkPanelModel) -> UIViewController
    ) {
        self.mode = mode
        self.makeReadyViewController = makeReadyViewController
        super.init(nibName: nil, bundle: nil)
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let mode = mode
        loadTask = Task { @MainActor [weak self] in
            do {
                let (runtime, model) = try await NetworkPreviewFixtures.start(
                    mode: mode
                )
                guard let self,
                      Task.isCancelled == false,
                      isRetired == false else {
                    await model.retire()
                    await runtime.close()
                    return
                }
                self.runtime = runtime
                self.model = model
                install(makeReadyViewController(model))
                loadTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      isRetired == false else {
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

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard view.window == nil else {
            return
        }
        beginRetirement()
    }

    isolated deinit {
        loadTask?.cancel()
        guard let runtime,
              let model else {
            return
        }
        Self.makeRetirementTask(runtime: runtime, model: model)
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

    private func beginRetirement() {
        guard isRetired == false else {
            return
        }
        isRetired = true
        loadTask?.cancel()
        guard let runtime,
              let model else {
            return
        }
        self.runtime = nil
        self.model = nil
        retirementTask = Self.makeRetirementTask(
            runtime: runtime,
            model: model
        )
    }

    @discardableResult
    private static func makeRetirementTask(
        runtime: WebInspectorDataKitTestRuntime,
        model: NetworkPanelModel
    ) -> Task<Void, Never> {
        Task { @MainActor in
            await model.retire()
            await runtime.close()
        }
    }
}

#Preview("Network List") {
    NetworkPreviewFixtures.makeViewController(mode: .root) { model in
        UINavigationController(
            rootViewController: NetworkListViewController(model: model)
        )
    }
}

#Preview("Network List Long Title") {
    NetworkPreviewFixtures.makeViewController(mode: .rootLongTitle) { model in
        UINavigationController(
            rootViewController: NetworkListViewController(model: model)
        )
    }
}

#Preview("Network Detail") {
    networkDetailPreview(mode: .detail)
}

#Preview("Network Detail Preview Response Only Short") {
    networkDetailPreview(mode: .detailResponseOnlyShort, initialMode: .preview)
}

#Preview("Network Detail Preview Request and Response Short") {
    networkDetailPreview(mode: .detailRequestAndResponseShort, initialMode: .preview)
}

#Preview("Network Detail Preview Response Only Long") {
    networkDetailPreview(mode: .detailResponseOnlyLong, initialMode: .preview)
}

#Preview("Network Detail Preview Request and Response Long") {
    networkDetailPreview(mode: .detailRequestAndResponseLong, initialMode: .preview)
}

#Preview("Network Split") {
    networkSplitPreview()
}

#Preview("Network Split Log Preview") {
    networkSplitPreview(initialMode: .preview, selectedDisplayName: "log")
}

@MainActor
private func networkDetailPreview(
    mode: NetworkPreviewFixtures.Mode,
    initialMode: NetworkDetailViewController.Mode = .headers
) -> UIViewController {
    NetworkPreviewFixtures.makeViewController(mode: mode) { model in
        UINavigationController(
            rootViewController: NetworkDetailViewController(
                model: model,
                initialMode: initialMode,
                makeBodyViewController:
                    NetworkBodyPreviewFactory.make(scrollEdgeSink:)
            )
        )
    }
}

@MainActor
private func networkSplitPreview(
    initialMode: NetworkDetailViewController.Mode = .headers,
    selectedDisplayName: String? = nil
) -> UIViewController {
    NetworkPreviewFixtures.makeViewController(mode: .detail) { model in
        if let selectedDisplayName,
           let entryID = model.entries.snapshot.itemIDs.first(where: { entryID in
               guard let entry = model.context.model(for: entryID),
                     let request = model.context.model(for: entry.primaryRequestID) else {
                   return false
               }
               return request.displayName == selectedDisplayName
           }) {
            model.selectEntry(entryID)
        }
        return NetworkCompactNavigationController(
            model: model,
            listViewController: NetworkListViewController(model: model),
            detailViewController: NetworkDetailViewController(
                model: model,
                initialMode: initialMode,
                makeBodyViewController:
                    NetworkBodyPreviewFactory.make(scrollEdgeSink:)
            )
        )
    }
}
#endif
