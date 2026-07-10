import Foundation
import WebInspectorProxyKit

package struct NetworkRequestRecordInput: Hashable, Sendable {
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
    package var hasResponse: Bool

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
        hasResponse = request.hasResponse
    }
}

package struct NetworkRequestRecord: Hashable, Sendable {
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
        let category = NetworkRequest.resourceCategory(
            resourceType: resourceType,
            mimeType: effectiveMIMEType,
            url: input.responseURL ?? input.url,
            hasResponse: input.hasResponse
        )
        resourceCategory = category
        searchableText = NetworkRequest.uniqueNonEmpty([
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
        ])
        .joined(separator: "\n")
        statusCode = input.statusCode
        requestSentTimestamp = input.requestSentTimestamp
    }

    package init(request: NetworkRequest, orderIndex: Int) {
        self.init(input: NetworkRequestRecordInput(request: request, orderIndex: orderIndex))
    }
}
