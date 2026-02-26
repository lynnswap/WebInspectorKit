#if DEBUG && canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit
@_spi(PreviewSupport) import WebInspectorEngine
import WebInspectorRuntime

@MainActor
private enum NetworkTabPreviewScenario {
    enum BodyPreviewVariant {
        case json
        case plainText
    }

    enum Mode {
        case list
        case listLongTitle
        case detail
        case bodyPreviewObjectTree
        case bodyPreviewText
    }

    static func makeInspector(mode: Mode) -> WINetworkModel {
        let session = NetworkSession()
        switch mode {
        case .listLongTitle:
            session.wiApplyPreviewBatch(sampleBatchPayload(includeLongTitle: true))
        case .bodyPreviewObjectTree:
            session.wiApplyPreviewBatch(sampleBatchPayload(bodyPreviewVariant: .json))
        case .bodyPreviewText:
            session.wiApplyPreviewBatch(sampleBatchPayload(bodyPreviewVariant: .plainText))
        case .list, .detail:
            session.wiApplyPreviewBatch(sampleBatchPayload())
        }
        let inspector = WINetworkModel(session: session)
        switch mode {
        case .detail, .bodyPreviewObjectTree, .bodyPreviewText:
            inspector.selectEntry(id: inspector.displayEntries.first?.id)
        default:
            break
        }
        return inspector
    }

    private static func sampleBatchPayload(
        includeLongTitle: Bool = false,
        bodyPreviewVariant: BodyPreviewVariant = .json
    ) -> NSDictionary {
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
            let basePayload = object as? NSDictionary
        else {
            return [
                "version": 1,
                "sessionId": "preview-session",
                "seq": 1,
                "events": []
            ]
        }
        let payload = NSMutableDictionary(dictionary: basePayload)

        if
            let events = payload["events"] as? NSArray,
            let mutableEvents = events.mutableCopy() as? NSMutableArray
        {
            for index in 0..<mutableEvents.count {
                guard let event = mutableEvents[index] as? NSDictionary else {
                    continue
                }
                guard (event["kind"] as? String) == "loadingFinished" else {
                    continue
                }
                let mutableEvent = NSMutableDictionary(dictionary: event)
                let body = (event["body"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary ?? NSMutableDictionary()
                let bodyText: String
                let bodyPreview: String
                switch bodyPreviewVariant {
                case .json:
                    bodyText = deepPreviewJSONText()
                    bodyPreview = deepPreviewJSONSummaryText()
                case .plainText:
                    bodyText = "status=ok; source=preview; mode=text"
                    bodyPreview = bodyText
                }
                body["kind"] = "text"
                body["size"] = bodyText.count
                body["truncated"] = false
                body["preview"] = bodyPreview
                body["content"] = bodyText
                mutableEvent["encodedBodyLength"] = bodyText.count
                mutableEvent["decodedBodySize"] = bodyText.count
                mutableEvent["body"] = body
                mutableEvents[index] = mutableEvent
                break
            }
            payload["events"] = mutableEvents
        }

        guard includeLongTitle else {
            return NSDictionary(dictionary: payload)
        }

        let events = NSMutableArray(array: (payload["events"] as? NSArray) ?? [])
        let startTime: [String: Double] = [
            "monotonicMs": 1900.0,
            "wallMs": 1700000000800.0
        ]
        let endTime: [String: Double] = [
            "monotonicMs": 2200.0,
            "wallMs": 1700000001100.0
        ]
        var insertedEvent: [String: Any] = [:]
        insertedEvent["kind"] = "resourceTiming"
        insertedEvent["requestId"] = 1999
        insertedEvent["url"] = "https://cdn.example.com/assets/network/preview/super-long-file-name-for-line-wrap-validation-with-json-tag-rendering-and-truncation-check.json"
        insertedEvent["method"] = "GET"
        insertedEvent["status"] = 200
        insertedEvent["statusText"] = "OK"
        insertedEvent["mimeType"] = "application/json"
        insertedEvent["startTime"] = startTime
        insertedEvent["endTime"] = endTime
        insertedEvent["encodedBodyLength"] = 512
        insertedEvent["decodedBodySize"] = 512
        insertedEvent["initiator"] = "xhr"
        events.insert(insertedEvent, at: 0)
        payload["events"] = events
        return NSDictionary(dictionary: payload)
    }

    private static func deepPreviewJSONSummaryText() -> String {
        """
        {"data":{"threaded_conversation_with_injections_v2":{"metadata":{"scribeConfig":{"page":"ranked_replies"}}}}}
        """
    }

    private static func deepPreviewJSONText() -> String {
        """
        {
          "data": {
            "threaded_conversation_with_injections_v2": {
              "instructions": [
                {
                  "type": "TimelineClearCache"
                },
                {
                  "type": "TimelineAddEntries",
                  "entries": [
                    {
                      "entryId": "tweet-1",
                      "content": {
                        "itemContent": {
                          "tweet_results": {
                            "result": {
                              "legacy": {
                                "full_text": "Preview tweet body"
                              }
                            }
                          }
                        }
                      }
                    }
                  ]
                }
              ],
              "metadata": {
                "reader_mode_config": {
                  "is_enabled": true
                },
                "scribeConfig": {
                  "page": "ranked_replies",
                  "context": {
                    "surface": "search",
                    "product": {
                      "name": "timeline",
                      "version": 2
                    }
                  }
                }
              }
            }
          },
          "source": "preview"
        }
        """
    }
}

@MainActor
private final class NetworkDetailPreviewHostViewController: UIViewController {
    var inspector: WINetworkModel?
    private var detailViewController: WINetworkDetailViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let inspector else {
            return
        }
        let detailViewController = WINetworkDetailViewController(inspector: inspector)
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
        detailViewController?.display(inspector.selectedEntry)
    }
}

@MainActor
private final class NetworkBodyPreviewHostViewController: UIViewController {
    var inspector: WINetworkModel?
    private var previewViewController: WINetworkBodyPreviewViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let inspector else {
            showPlaceholder(message: "Inspector not available")
            return
        }

        let entryWithBody = inspector.displayEntries.first { entry in
            entry.responseBody != nil || entry.requestBody != nil
        }
        guard let entry = entryWithBody else {
            showPlaceholder(message: "No preview body entry found")
            return
        }

        guard let body = entry.responseBody ?? entry.requestBody else {
            showPlaceholder(message: "Body payload is empty")
            return
        }

        let previewViewController = WINetworkBodyPreviewViewController(
            entry: entry,
            inspector: inspector,
            bodyState: body
        )
        self.previewViewController = previewViewController

        let navigationController = UINavigationController(rootViewController: previewViewController)
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

    private func showPlaceholder(message: String) {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = message
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
}

@MainActor
private struct NetworkTabPreviewContainer: UIViewControllerRepresentable {
    let mode: NetworkTabPreviewScenario.Mode

    func makeUIViewController(context: Context) -> UIViewController {
        switch mode {
        case .list:
            let inspector = NetworkTabPreviewScenario.makeInspector(mode: .list)
            return WINetworkViewController(inspector: inspector)
        case .listLongTitle:
            let inspector = NetworkTabPreviewScenario.makeInspector(mode: .listLongTitle)
            return WINetworkViewController(inspector: inspector)
        case .detail:
            let inspector = NetworkTabPreviewScenario.makeInspector(mode: .detail)
            let host = NetworkDetailPreviewHostViewController()
            host.inspector = inspector
            return host
        case .bodyPreviewObjectTree:
            let inspector = NetworkTabPreviewScenario.makeInspector(mode: .bodyPreviewObjectTree)
            let host = NetworkBodyPreviewHostViewController()
            host.inspector = inspector
            return host
        case .bodyPreviewText:
            let inspector = NetworkTabPreviewScenario.makeInspector(mode: .bodyPreviewText)
            let host = NetworkBodyPreviewHostViewController()
            host.inspector = inspector
            return host
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

#Preview("Network Root") {
    NetworkTabPreviewContainer(mode: .list)
}

#Preview("Network Root Long Title") {
    NetworkTabPreviewContainer(mode: .listLongTitle)
}

#Preview("Network Detail") {
    NetworkTabPreviewContainer(mode: .detail)
}

#Preview("Network Body Preview Object Tree") {
    NetworkTabPreviewContainer(mode: .bodyPreviewObjectTree)
}

#Preview("Network Body Preview Text") {
    NetworkTabPreviewContainer(mode: .bodyPreviewText)
}
#endif
