import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@Test
func transitionalNetworkAndDOMIDsNeverInferCanonicalAuthority() {
    let storeID = WebInspectorContainerStoreID(
        rawValue: UUID(
            uuid: (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 9
            )
        )
    )
    let attachment = WebInspectorContainerAttachmentGeneration(rawValue: 3)
    let page = WebInspectorPage.Generation(rawValue: 4)
    let rawRequestID = Network.Request.ID("same")
    let canonicalRequestStorage = CanonicalNetworkRequestIDStorage(
        storeID: storeID,
        attachmentGeneration: attachment,
        pageGeneration: page,
        agentTargetID: WebInspectorTarget.ID("agent"),
        rawRequestID: rawRequestID
    )
    let legacyRequestID = NetworkRequest.ID(rawRequestID)
    let canonicalRequestID = NetworkRequest.ID(
        canonical: canonicalRequestStorage
    )
    #expect(legacyRequestID != canonicalRequestID)
    #expect(legacyRequestID.canonicalStorage == nil)
    #expect(canonicalRequestID.canonicalStorage == canonicalRequestStorage)
    #expect(canonicalRequestID.proxyID == rawRequestID)

    let rawNodeID = DOM.Node.ID("same")
    let documentScope = WebInspectorDOMDocumentScopeStorage(
        storeID: storeID,
        attachmentGeneration: attachment,
        pageGeneration: page,
        semanticTargetID: WebInspectorTarget.ID("page"),
        agentTargetID: WebInspectorTarget.ID("agent"),
        domBindingEpoch: ModelDOMBindingEpoch(rawValue: 5)
    )
    let canonicalNodeStorage = WebInspectorDOMNodeIdentityStorage(
        documentScope: documentScope,
        rawNodeID: rawNodeID
    )
    let legacyNodeID = DOMNode.ID(rawNodeID)
    let canonicalNodeID = DOMNode.ID(canonical: canonicalNodeStorage)
    #expect(legacyNodeID != canonicalNodeID)
    #expect(legacyNodeID.canonicalStorage == nil)
    #expect(canonicalNodeID.canonicalStorage == canonicalNodeStorage)
    #expect(canonicalNodeID.proxyID == rawNodeID)
}
