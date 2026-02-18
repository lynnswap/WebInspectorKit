#if DEBUG && canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit
@_spi(PreviewSupport) import WebInspectorKitCore

@MainActor
private enum NetworkTabPreviewScenario {
    enum Mode {
        case list
        case detail
    }

    static func makeInspector(mode: Mode) -> WebInspector.NetworkInspector {
        let session = NetworkSession()
        session.wiApplyPreviewBatch(sampleBatchPayload())
        let inspector = WebInspector.NetworkInspector(session: session)
        if mode == .detail {
            inspector.selectedEntryID = inspector.displayEntries.first?.id
        }
        return inspector
    }

    private static func sampleBatchPayload() -> [String: Any] {
        let sampleJSON = """
        {
          "version": 1,
          "sessionId": "preview-session",
          "seq": 1,
          "events": [
            {
              "kind": "requestWillBeSent",
              "requestId": 1001,
              "time": { "monotonicMs": 1000.0, "wallMs": 1700000000000.0 },
              "url": "https://play.google.com/log?format=json&hasfast=true",
              "method": "POST",
              "headers": {
                "authorization": "Bearer preview-token",
                "content-type": "application/x-www-form-urlencoded"
              },
              "body": {
                "kind": "text",
                "size": 64,
                "truncated": false,
                "preview": "hl=ja&gl=JP&source=wi-preview"
              },
              "bodySize": 64,
              "initiator": "xhr"
            },
            {
              "kind": "responseReceived",
              "requestId": 1001,
              "time": { "monotonicMs": 1119.0, "wallMs": 1700000000119.0 },
              "status": 200,
              "statusText": "OK",
              "mimeType": "application/json",
              "headers": {
                "content-length": "131",
                "content-type": "application/json; charset=utf-8"
              },
              "initiator": "xhr"
            },
            {
              "kind": "loadingFinished",
              "requestId": 1001,
              "time": { "monotonicMs": 1119.0, "wallMs": 1700000000119.0 },
              "encodedBodyLength": 131,
              "decodedBodySize": 131,
              "body": {
                "kind": "text",
                "size": 131,
                "truncated": false,
                "preview": "{\\"result\\":\\"ok\\",\\"items\\":[1,2,3]}",
                "content": "{\\"result\\":\\"ok\\",\\"items\\":[1,2,3],\\"source\\":\\"preview\\"}"
              },
              "initiator": "xhr"
            },
            {
              "kind": "resourceTiming",
              "requestId": 1002,
              "url": "https://www.gstatic.com/images/icons/material/system/2x/trending_up_grey600_24dp.png",
              "method": "GET",
              "status": 200,
              "statusText": "OK",
              "mimeType": "image/png",
              "startTime": { "monotonicMs": 900.0, "wallMs": 1699999999400.0 },
              "endTime": { "monotonicMs": 1728.0, "wallMs": 1700000000228.0 },
              "encodedBodyLength": 0,
              "decodedBodySize": 0,
              "initiator": "img"
            },
            {
              "kind": "resourceTiming",
              "requestId": 1003,
              "url": "https://www.gstatic.com/og/_/js/k=og.qtm.en_US.ABC.js",
              "method": "GET",
              "status": 404,
              "statusText": "Not Found",
              "mimeType": "application/javascript",
              "startTime": { "monotonicMs": 850.0, "wallMs": 1699999999280.0 },
              "endTime": { "monotonicMs": 1560.0, "wallMs": 1699999999990.0 },
              "encodedBodyLength": 0,
              "decodedBodySize": 0,
              "error": {
                "domain": "Network",
                "code": "404",
                "message": "Not Found"
              },
              "initiator": "script"
            }
          ]
        }
        """
        guard
            let data = sampleJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let payload = object as? [String: Any]
        else {
            return [
                "version": 1,
                "sessionId": "preview-session",
                "seq": 1,
                "events": []
            ]
        }
        return payload
    }
}

@MainActor
private final class NetworkDetailPreviewHostViewController: UIViewController {
    var inspector: WebInspector.NetworkInspector?
    private var detailViewController: NetworkDetailViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let inspector else {
            return
        }
        let detailViewController = NetworkDetailViewController(inspector: inspector)
        self.detailViewController = detailViewController

        let navigationController = UINavigationController(rootViewController: detailViewController)
        addChild(navigationController)
        navigationController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(navigationController.view)
        NSLayoutConstraint.activate([
            navigationController.view.topAnchor.constraint(equalTo: view.topAnchor),
            navigationController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navigationController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            navigationController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        navigationController.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let inspector else {
            return
        }
        detailViewController?.display(inspector.store.entry(forEntryID: inspector.selectedEntryID))
    }
}

@MainActor
private struct NetworkTabPreviewContainer: UIViewControllerRepresentable {
    let mode: NetworkTabPreviewScenario.Mode

    func makeUIViewController(context: Context) -> UIViewController {
        switch mode {
        case .list:
            let inspector = NetworkTabPreviewScenario.makeInspector(mode: .list)
            return NetworkTabViewController(inspector: inspector)
        case .detail:
            let inspector = NetworkTabPreviewScenario.makeInspector(mode: .detail)
            let host = NetworkDetailPreviewHostViewController()
            host.inspector = inspector
            return host
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

#Preview("Network Root") {
    NetworkTabPreviewContainer(mode: .list)
}

#Preview("Network Detail") {
    NetworkTabPreviewContainer(mode: .detail)
}
#endif
