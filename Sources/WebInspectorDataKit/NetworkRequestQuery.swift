import Foundation
import WebInspectorProxyKit

package enum NetworkRequestGroupIdentity {
    private static let initiatorNodeNamespace = "network.initiator-node:"
    private static let uninitiatedRequestNamespace = "network.uninitiated-request:"

    package static func sectionID(
        requestID: NetworkRequest.ID,
        initiatorNodeIDRawValue: String?
    ) -> WebInspectorFetchSectionID {
        if let initiatorNodeIDRawValue {
            return WebInspectorFetchSectionID(
                rawValue: initiatorNodeNamespace + initiatorNodeIDRawValue
            )
        }
        return WebInspectorFetchSectionID(
            rawValue: uninitiatedRequestNamespace + requestID.proxyID.rawValue
        )
    }
}

package struct NetworkRequestChronologyKey: Hashable, Sendable {
    package var requestSentTimestamp: Double?
    package var orderIndex: Int

    package static func ordersBefore(
        _ lhs: NetworkRequestChronologyKey,
        _ rhs: NetworkRequestChronologyKey
    ) -> Bool {
        switch (lhs.requestSentTimestamp, rhs.requestSentTimestamp) {
        case (nil, nil):
            return lhs.orderIndex < rhs.orderIndex
        case (nil, _):
            return true
        case (_, nil):
            return false
        case let (lhsTimestamp?, rhsTimestamp?):
            if lhsTimestamp < rhsTimestamp {
                return true
            }
            if lhsTimestamp > rhsTimestamp {
                return false
            }
            return lhs.orderIndex < rhs.orderIndex
        }
    }
}

package struct NetworkRequestRedirectSearchInput: Hashable, Sendable {
    package var requestURL: String
    package var requestMethod: String
    package var responseURL: String?
    package var responseStatus: Int?
    package var responseStatusText: String?
    package var responseMIMEType: String?
}

package struct NetworkRequestRecordInput: Hashable, Sendable, Identifiable {
    package var id: NetworkRequest.ID
    package var orderIndex: Int
    package var url: String
    package var method: String
    package var resourceTypeRawValue: String?
    package var mimeType: String?
    package var responseURL: String?
    package var responseHeaders: [String: String]
    package var statusCode: Int?
    package var statusText: String?
    package var requestSentTimestamp: Double?
    package var responseReceivedTimestamp: Double?
    package var responseSource: String?
    package var initiatorNodeIDRawValue: String?
    package var redirectSearchInputs: [NetworkRequestRedirectSearchInput]

    package var chronologyKey: NetworkRequestChronologyKey {
        NetworkRequestChronologyKey(
            requestSentTimestamp: requestSentTimestamp,
            orderIndex: orderIndex
        )
    }

    package var groupID: WebInspectorFetchSectionID {
        NetworkRequestGroupIdentity.sectionID(
            requestID: id,
            initiatorNodeIDRawValue: initiatorNodeIDRawValue
        )
    }

    package init(request: NetworkRequest, orderIndex: Int) {
        id = request.id
        self.orderIndex = orderIndex
        url = request.url
        method = request.method
        resourceTypeRawValue = request.resourceType?.rawValue
        mimeType = request.mimeType
        responseURL = request.responseURL
        responseHeaders = request.responseHeaders
        statusCode = request.statusCode
        statusText = request.statusText
        requestSentTimestamp = request.requestSentTimestamp
        responseReceivedTimestamp = request.responseReceivedTimestamp
        responseSource = request.responseSource
        initiatorNodeIDRawValue = request.initiator?.nodeID?.rawValue
        redirectSearchInputs = request.redirects.map { redirect in
            NetworkRequestRedirectSearchInput(
                requestURL: redirect.request.url,
                requestMethod: redirect.request.method,
                responseURL: redirect.response.url,
                responseStatus: redirect.response.status,
                responseStatusText: redirect.response.statusText,
                responseMIMEType: redirect.response.mimeType
            )
        }
    }
}

package struct NetworkRequestRecord: Hashable, Sendable, Identifiable {
    package var id: NetworkRequest.ID
    package var orderIndex: Int
    package var url: String
    package var method: String
    package var resourceTypeRawValue: String?
    package var mimeType: String?
    package var resourceCategory: NetworkRequest.ResourceCategory
    package var searchableText: String
    package var statusCode: Int?
    package var requestSentTimestamp: Double?
    package var groupID: WebInspectorFetchSectionID
    package var chronologyKey: NetworkRequestChronologyKey

    package init(input: NetworkRequestRecordInput) {
        id = input.id
        orderIndex = input.orderIndex
        url = input.url
        method = input.method
        resourceTypeRawValue = input.resourceTypeRawValue
        mimeType = input.mimeType
        let resourceType = input.resourceTypeRawValue.map(Network.ResourceType.init(rawValue:))
        let effectiveMIMEType = NetworkRequest.effectiveMIMEType(
            mimeType: input.mimeType,
            headers: input.responseHeaders
        )
        let hasResponse = input.responseReceivedTimestamp != nil
            || input.statusCode != nil
            || input.statusText != nil
            || input.responseURL != nil
            || input.mimeType != nil
            || input.responseHeaders.isEmpty == false
            || input.responseSource != nil
        let category = NetworkRequest.resourceCategory(
            resourceType: resourceType,
            mimeType: effectiveMIMEType,
            url: input.responseURL ?? input.url,
            hasResponse: hasResponse
        )
        resourceCategory = category
        let currentFields: [String?] = [
            input.url,
            input.responseURL,
            NetworkRequest.urlSearchText(input.url),
            input.responseURL.map(NetworkRequest.urlSearchText),
            input.method,
            input.statusCode.map(String.init),
            input.statusText,
            input.mimeType,
            input.resourceTypeRawValue,
            category.rawValue,
        ]
        let redirectFields: [String?] = input.redirectSearchInputs.flatMap { redirect in
            [
                redirect.requestURL,
                NetworkRequest.urlSearchText(redirect.requestURL),
                redirect.requestMethod,
                redirect.responseURL,
                redirect.responseURL.map(NetworkRequest.urlSearchText),
                redirect.responseStatus.map(String.init),
                redirect.responseStatusText,
                redirect.responseMIMEType,
            ]
        }
        searchableText = NetworkRequest.uniqueNonEmpty(currentFields + redirectFields)
            .joined(separator: "\n")
        statusCode = input.statusCode
        requestSentTimestamp = input.requestSentTimestamp
        groupID = input.groupID
        chronologyKey = input.chronologyKey
    }
}
