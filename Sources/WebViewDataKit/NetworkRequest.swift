import Foundation
import Observation
import WebViewProxyKit

public protocol WebViewFetchableModel: AnyObject {}

@MainActor
@Observable
public final class NetworkBody {
    public enum Phase: Equatable, Sendable {
        case available
        case fetching
        case loaded
        case failed(WebViewProxyError)
    }

    public private(set) var phase: Phase
    public private(set) var text: String?
    public private(set) var isBase64Encoded: Bool

    package init(phase: Phase = .available, text: String? = nil, isBase64Encoded: Bool = false) {
        self.phase = phase
        self.text = text
        self.isBase64Encoded = isBase64Encoded
    }

    package func markFetching() {
        phase = .fetching
    }

    package func load(_ body: Network.Body) {
        text = body.data
        isBase64Encoded = body.base64Encoded
        phase = .loaded
    }

    package func fail(_ error: WebViewProxyError) {
        phase = .failed(error)
    }
}

@MainActor
@Observable
public final class NetworkRequest: Identifiable, WebViewFetchableModel {
    public struct ID: Hashable, Sendable {
        package let proxyID: Network.Request.ID

        package init(_ proxyID: Network.Request.ID) {
            self.proxyID = proxyID
        }
    }

    public enum State: Equatable, Sendable {
        case pending
        case responded
        case finished
        case failed(errorText: String, canceled: Bool)
    }

    public let id: ID
    public private(set) var url: String
    public private(set) var method: String
    public private(set) var resourceType: Network.ResourceType?
    public private(set) var state: State
    public private(set) var status: Int?
    public private(set) var mimeType: String?
    public private(set) var requestHeaders: [String: String]
    public private(set) var responseHeaders: [String: String]
    public private(set) var responseBody: NetworkBody

    @ObservationIgnored package weak var modelContext: WebViewModelContext?

    package var proxyID: Network.Request.ID {
        id.proxyID
    }

    package init(
        request: Network.Request,
        resourceType: Network.ResourceType?,
        modelContext: WebViewModelContext
    ) {
        id = ID(request.id)
        url = request.url
        method = request.method
        self.resourceType = resourceType
        state = .pending
        status = nil
        mimeType = nil
        requestHeaders = request.headers
        responseHeaders = [:]
        responseBody = NetworkBody()
        self.modelContext = modelContext
    }

    public func fetchResponseBody() async {
        responseBody.markFetching()
        guard let modelContext else {
            responseBody.fail(.disconnected("NetworkRequest is not registered in a WebViewModelContext."))
            return
        }
        await modelContext.fetchResponseBody(for: self)
    }

    package func applyRequestWillBeSent(
        request: Network.Request,
        resourceType: Network.ResourceType?
    ) {
        url = request.url
        method = request.method
        self.resourceType = resourceType
        requestHeaders = request.headers
        status = nil
        mimeType = nil
        responseHeaders = [:]
        responseBody = NetworkBody()
        state = .pending
    }

    package func applyResponse(
        _ response: Network.Response,
        resourceType: Network.ResourceType
    ) {
        self.resourceType = resourceType
        status = response.status
        mimeType = response.mimeType
        responseHeaders = response.headers
        if let requestHeaders = response.requestHeaders {
            self.requestHeaders = requestHeaders
        }
        state = .responded
    }

    package func applyDataReceived(dataLength: Int) {
        _ = dataLength
        if state == .pending {
            state = .responded
        }
    }

    package func finish() {
        state = .finished
    }

    package func fail(errorText: String, canceled: Bool) {
        state = .failed(errorText: errorText, canceled: canceled)
    }

    package func finishResponseBodyFetch(result: Result<Network.Body, WebViewProxyError>) {
        switch result {
        case let .success(body):
            responseBody.load(body)
        case let .failure(error):
            responseBody.fail(error)
        }
    }
}
