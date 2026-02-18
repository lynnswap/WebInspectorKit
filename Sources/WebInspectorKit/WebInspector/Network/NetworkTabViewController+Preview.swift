#if DEBUG && canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit
@_spi(PreviewSupport) import WebInspectorKitCore

@MainActor
private final class NetworkTabPreviewHostViewController: UIViewController {
    private let rootViewController: UIViewController
    private let detailViewController: NetworkDetailViewController?
    private let detailEntry: NetworkEntry?

    init(mode: NetworkTabPreviewScenario.Mode) {
        let inspector = NetworkTabPreviewScenario.makeInspector(mode: mode)
        switch mode {
        case .list:
            self.rootViewController = NetworkTabViewController(inspector: inspector)
            self.detailViewController = nil
            self.detailEntry = nil
        case .detail:
            let detailViewController = NetworkDetailViewController(inspector: inspector)
            self.rootViewController = UINavigationController(rootViewController: detailViewController)
            self.detailViewController = detailViewController
            self.detailEntry = inspector.store.entry(forEntryID: inspector.selectedEntryID)
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(rootViewController)
        rootViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootViewController.view)

        NSLayoutConstraint.activate([
            rootViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            rootViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        rootViewController.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        detailViewController?.display(detailEntry)
    }
}

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
private struct NetworkTabPreviewContainer: UIViewControllerRepresentable {
    let mode: NetworkTabPreviewScenario.Mode

    func makeUIViewController(context: Context) -> UIViewController {
        NetworkTabPreviewHostViewController(mode: mode)
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
