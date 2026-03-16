import Foundation
import Testing
import WebInspectorCore
@testable import WebInspectorTransport

@MainActor
struct WITransportEventTranslatorTests {
    @Test
    func domTranslatorMatchesObjectAndDataPathsForSetChildNodes() throws {
        let payload: [String: Any] = [
            "parentId": 7,
            "nodes": [
                [
                    "nodeId": 8,
                    "nodeType": 1,
                    "nodeName": "DIV",
                    "localName": "div",
                    "nodeValue": "",
                    "childNodeCount": 0,
                    "attributes": ["id", "hero"],
                    "children": [],
                    "layoutFlags": ["rendered"],
                ],
            ],
        ]

        let objectUpdate = translator.translate(
            domEnvelope(method: "DOM.setChildNodes", payload: .object(payload)),
            nodeDescriptor: nodeDescriptor(from:)
        )
        let dataUpdate = translator.translate(
            domEnvelope(method: "DOM.setChildNodes", payload: .data(jsonData(payload))),
            nodeDescriptor: nodeDescriptor(from:)
        )

        guard case let .setChildNodes(objectParentID, objectNodes)? = objectUpdate,
              case let .setChildNodes(dataParentID, dataNodes)? = dataUpdate else {
            Issue.record("Expected DOM.setChildNodes translation results.")
            return
        }

        #expect(objectParentID == dataParentID)
        #expect(objectNodes.count == 1)
        #expect(dataNodes.count == 1)
        #expect(objectNodes[0].nodeId == dataNodes[0].nodeId)
        #expect(objectNodes[0].localName == dataNodes[0].localName)
        #expect(objectNodes[0].layoutFlags == dataNodes[0].layoutFlags)
    }

    @Test
    func domTranslatorMatchesObjectAndDataPathsForAttributeMutation() throws {
        let payload: [String: Any] = [
            "nodeId": 42,
            "name": "class",
            "value": "selected",
        ]

        let objectUpdate = translator.translate(
            domEnvelope(method: "DOM.attributeModified", payload: .object(payload)),
            nodeDescriptor: nodeDescriptor(from:)
        )
        let dataUpdate = translator.translate(
            domEnvelope(method: "DOM.attributeModified", payload: .data(jsonData(payload))),
            nodeDescriptor: nodeDescriptor(from:)
        )

        guard case let .mutation(.attributeModified(objectNodeID, objectName, objectValue, _, _))? = objectUpdate,
              case let .mutation(.attributeModified(dataNodeID, dataName, dataValue, _, _))? = dataUpdate else {
            Issue.record("Expected DOM.attributeModified translation results.")
            return
        }

        #expect(objectNodeID == dataNodeID)
        #expect(objectName == dataName)
        #expect(objectValue == dataValue)
    }

    @Test
    func networkTranslatorMatchesObjectAndDataPathsForRequestWillBeSent() {
        let payload: [String: Any] = [
            "requestId": "request-1",
            "frameId": "frame-A",
            "timestamp": 12.5,
            "walltime": 34.5,
            "type": "Script",
            "request": [
                "url": "https://example.com/app.js",
                "method": "GET",
                "headers": ["Accept": "*/*"],
            ],
            "redirectResponse": [
                "url": "https://example.com/old.js",
                "status": 302,
                "statusText": "Found",
                "headers": ["Location": "https://example.com/app.js"],
                "mimeType": "text/javascript",
            ],
        ]

        let objectEvent = networkTranslator.translate(
            networkEnvelope(method: "Network.requestWillBeSent", payload: .object(payload))
        )
        let dataEvent = networkTranslator.translate(
            networkEnvelope(method: "Network.requestWillBeSent", payload: .data(jsonData(payload)))
        )

        guard case let .requestWillBeSent(objectParams, objectTarget)? = objectEvent,
              case let .requestWillBeSent(dataParams, dataTarget)? = dataEvent else {
            Issue.record("Expected Network.requestWillBeSent translation results.")
            return
        }

        #expect(objectTarget == dataTarget)
        #expect(objectParams.requestId == dataParams.requestId)
        #expect(objectParams.request.url == dataParams.request.url)
        #expect(objectParams.request.headers == dataParams.request.headers)
        #expect(objectParams.redirectResponse?.url == dataParams.redirectResponse?.url)
        #expect(objectParams.redirectResponse?.status == dataParams.redirectResponse?.status)
    }

    @Test
    func networkTranslatorMatchesObjectAndDataPathsForWebSocketFrames() {
        let payload: [String: Any] = [
            "requestId": "socket-1",
            "timestamp": 7.0,
            "response": [
                "opcode": 1,
                "mask": false,
                "payloadData": "hello",
                "payloadLength": 5,
            ],
        ]

        let objectEvent = networkTranslator.translate(
            networkEnvelope(method: "Network.webSocketFrameReceived", payload: .object(payload))
        )
        let dataEvent = networkTranslator.translate(
            networkEnvelope(method: "Network.webSocketFrameReceived", payload: .data(jsonData(payload)))
        )

        guard case let .webSocketFrameReceived(objectParams, objectTarget)? = objectEvent,
              case let .webSocketFrameReceived(dataParams, dataTarget)? = dataEvent else {
            Issue.record("Expected Network.webSocketFrameReceived translation results.")
            return
        }

        #expect(objectTarget == dataTarget)
        #expect(objectParams.requestId == dataParams.requestId)
        #expect(objectParams.response.payloadData == dataParams.response.payloadData)
        #expect(objectParams.response.payloadLength == dataParams.response.payloadLength)
        #expect(objectParams.response.opcode == dataParams.response.opcode)
    }
}

private extension WITransportEventTranslatorTests {
    var translator: DOMTransportEventTranslator {
        DOMTransportEventTranslator()
    }

    var networkTranslator: NetworkEventTranslator {
        NetworkEventTranslator()
    }

    func domEnvelope(method: String, payload: WITransportPayload) -> WITransportEventEnvelope {
        WITransportEventEnvelope(
            method: method,
            targetScope: .page,
            targetIdentifier: "page-A",
            paramsPayload: payload
        )
    }

    func networkEnvelope(method: String, payload: WITransportPayload) -> WITransportEventEnvelope {
        WITransportEventEnvelope(
            method: method,
            targetScope: .page,
            targetIdentifier: "page-A",
            paramsPayload: payload
        )
    }

    func nodeDescriptor(from node: WITransportDOMNode) -> DOMGraphNodeDescriptor {
        let attributes: [DOMAttribute]
        if let rawAttributes = node.attributes {
            attributes = stride(from: 0, to: rawAttributes.count, by: 2).map { index in
                let name = rawAttributes[index]
                let value = index + 1 < rawAttributes.count ? rawAttributes[index + 1] : ""
                return DOMAttribute(nodeId: node.nodeId, name: name, value: value)
            }
        } else {
            attributes = []
        }

        return DOMGraphNodeDescriptor(
            nodeID: node.nodeId,
            nodeType: node.nodeType,
            nodeName: node.nodeName,
            localName: node.localName,
            nodeValue: node.nodeValue,
            attributes: attributes,
            childCount: node.childNodeCount ?? 0,
            layoutFlags: node.layoutFlags ?? [],
            isRendered: true,
            children: []
        )
    }

    func jsonData(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}
