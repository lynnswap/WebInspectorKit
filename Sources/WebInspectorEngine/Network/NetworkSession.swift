import Foundation
import WebKit
import WebInspectorTransport

@MainActor
package protocol NetworkBodyFetching: AnyObject {
    func supportsDeferredLoading(for role: NetworkBody.Role) -> Bool
    func fetchBodyResult(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> NetworkBodyFetchResult
}

extension NetworkBodyFetching {
    func supportsDeferredLoading(for role: NetworkBody.Role) -> Bool {
        true
    }
}

package enum NetworkBodyFetchResult {
    case fetched(NetworkBody)
    case agentUnavailable
    case bodyUnavailable
}

@MainActor
public final class NetworkSession: PageSession {
    private struct BodyFetchKey: Hashable {
        let entryID: UUID
        let role: NetworkBody.Role
    }

    private struct DefaultPageAgentComponents {
        let pageAgent: any NetworkPageDriving
        let bodyFetcher: any NetworkBodyFetching
        let transportCapabilityProvider: (any InspectorTransportCapabilityProviding)?
        let transportSupportSnapshot: WITransportSupportSnapshot?
    }

    public typealias AttachmentResult = Void

    public var configuration: NetworkConfiguration {
        didSet {
            store.maxEntries = configuration.maxEntries
        }
    }

    private(set) var mode: NetworkLoggingMode = .active

    public let store: NetworkStore
    public private(set) weak var lastPageWebView: WKWebView?
    private let pageAgent: any NetworkPageDriving
    private let bodyFetcher: any NetworkBodyFetching
    private let transportCapabilityProvider: (any InspectorTransportCapabilityProviding)?
    private let fallbackTransportSupportSnapshot: WITransportSupportSnapshot?
    private var bodyFetchTasks: [BodyFetchKey: (token: UUID, task: Task<Void, Never>)] = [:]

    var hasAttachedPageWebView: Bool {
        pageAgent.webView != nil
    }

    package var transportCapabilities: Set<InspectorTransportCapability> {
        let fallbackCapabilities = Self.fallbackTransportCapabilities(from: fallbackTransportSupportSnapshot)
        guard let providerCapabilities = transportCapabilityProvider?.inspectorTransportCapabilities else {
            return fallbackCapabilities
        }
        return providerCapabilities.union(fallbackCapabilities)
    }

    public var transportSupportSnapshot: WITransportSupportSnapshot? {
        transportCapabilityProvider?.inspectorTransportSupportSnapshot ?? fallbackTransportSupportSnapshot
    }

    public convenience init(configuration: NetworkConfiguration = .init()) {
        let components = Self.makeDefaultPageAgentComponents()
        self.init(
            configuration: configuration,
            pageAgent: components.pageAgent,
            bodyFetcher: components.bodyFetcher,
            transportCapabilityProvider: components.transportCapabilityProvider,
            transportSupportSnapshot: components.transportSupportSnapshot
        )
    }

    package convenience init(
        configuration: NetworkConfiguration = .init(),
        defaultTransportSupportSnapshot: WITransportSupportSnapshot
    ) {
        let components = Self.makeDefaultPageAgentComponents(
            transportSupportSnapshot: defaultTransportSupportSnapshot
        )
        self.init(
            configuration: configuration,
            pageAgent: components.pageAgent,
            bodyFetcher: components.bodyFetcher,
            transportCapabilityProvider: components.transportCapabilityProvider,
            transportSupportSnapshot: components.transportSupportSnapshot
        )
    }

    package convenience init(
        configuration: NetworkConfiguration = .init(),
        bodyFetcher: any NetworkBodyFetching
    ) {
        self.init(
            configuration: configuration,
            bodyFetcher: bodyFetcher,
            defaultTransportSupportSnapshot: WITransportSession().supportSnapshot
        )
    }

    package convenience init(
        configuration: NetworkConfiguration = .init(),
        bodyFetcher: any NetworkBodyFetching,
        defaultTransportSupportSnapshot: WITransportSupportSnapshot
    ) {
        let preflightSnapshot = defaultTransportSupportSnapshot
        let driver: any NetworkPageDriving
        let capabilityProvider: (any InspectorTransportCapabilityProviding)?

        if Self.shouldUseTransportDriver(for: preflightSnapshot) {
            let transportDriver = NetworkTransportDriver()
            driver = transportDriver
            capabilityProvider = transportDriver
        } else {
            driver = NetworkLegacyPageDriver()
            capabilityProvider = nil
        }

        self.init(
            configuration: configuration,
            pageAgent: driver,
            bodyFetcher: bodyFetcher,
            transportCapabilityProvider: capabilityProvider,
            transportSupportSnapshot: preflightSnapshot
        )
    }

    init(
        configuration: NetworkConfiguration,
        pageAgent: any NetworkPageDriving,
        bodyFetcher: any NetworkBodyFetching,
        transportCapabilityProvider: (any InspectorTransportCapabilityProviding)? = nil,
        transportSupportSnapshot: WITransportSupportSnapshot? = nil
    ) {
        self.configuration = configuration
        self.pageAgent = pageAgent
        self.bodyFetcher = bodyFetcher
        self.transportCapabilityProvider = transportCapabilityProvider
        fallbackTransportSupportSnapshot = transportSupportSnapshot
        self.store = pageAgent.store
        self.store.maxEntries = configuration.maxEntries
    }

    public func attach(pageWebView webView: WKWebView) {
        pageAgent.setMode(mode)
        pageAgent.attachPageWebView(webView)
        lastPageWebView = webView
    }

    public func suspend() {
        cancelAllBodyFetches()
        mode = .stopped
        pageAgent.detachPageWebView(preparing: .stopped)
    }

    public func detach() {
        cancelAllBodyFetches()
        mode = .stopped
        pageAgent.detachPageWebView(preparing: .stopped)
        lastPageWebView = nil
    }

    public func setMode(_ mode: NetworkLoggingMode) {
        self.mode = mode
        pageAgent.setMode(mode)
    }

    public func clearNetworkLogs() {
        cancelAllBodyFetches()
        pageAgent.clearNetworkLogs()
    }

    package func cancelBodyFetches(for entry: NetworkEntry) {
        cancelBodyFetch(for: BodyFetchKey(entryID: entry.id, role: .request), entry: entry)
        cancelBodyFetch(for: BodyFetchKey(entryID: entry.id, role: .response), entry: entry)
    }

    public func fetchBody(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> NetworkBody? {
        switch await bodyFetcher.fetchBodyResult(ref: ref, handle: handle, role: role) {
        case .fetched(let body):
            return body
        case .agentUnavailable, .bodyUnavailable:
            return nil
        }
    }

    package func requestBodyIfNeeded(for entry: NetworkEntry, role: NetworkBody.Role) {
        guard hasAttachedPageWebView else {
            return
        }
        guard let body = body(for: entry, role: role) else {
            return
        }
        guard shouldFetch(body) else {
            return
        }
        guard bodyFetcher.supportsDeferredLoading(for: role) else {
            return
        }

        let bodyRef = body.reference
        let bodyHandle = body.handle
        let hasReference = bodyRef?.isEmpty == false
        let hasHandle = bodyHandle != nil
        guard hasReference || hasHandle else {
            body.markFailed(.unavailable)
            return
        }

        let key = BodyFetchKey(entryID: entry.id, role: role)
        body.markFetching()
        let token = UUID()
        let task = Task { @MainActor [weak self, weak entry, weak body] in
            defer {
                self?.clearBodyFetchTask(for: key, token: token)
            }
            guard let self, let entry, let body else {
                return
            }

            let fetchResult = await self.bodyFetcher.fetchBodyResult(ref: bodyRef, handle: bodyHandle, role: role)

            guard !Task.isCancelled else {
                self.resetBodyToInlineIfFetching(for: entry, role: role, expectedBody: body)
                return
            }

            guard self.body(for: entry, role: role) === body else {
                return
            }
            guard self.hasAttachedPageWebView else {
                self.resetBodyToInlineIfFetching(for: entry, role: role, expectedBody: body)
                return
            }
            switch fetchResult {
            case .fetched(let fetched):
                entry.applyFetchedBody(fetched, to: body)
            case .agentUnavailable, .bodyUnavailable:
                body.markFailed(.unavailable)
            }
        }
        bodyFetchTasks[key] = (token, task)
    }

    package func prepareForTransportRebind() {
        guard transportSupportSnapshot?.backendKind == .macOSNativeInspector else {
            return
        }

        cancelAllBodyFetches()
        (pageAgent as? NetworkTransportRebindDriving)?.prepareForTransportRebind()
    }

    package func resumeAfterTransportRebind(to webView: WKWebView) {
        guard transportSupportSnapshot?.backendKind == .macOSNativeInspector else {
            return
        }

        lastPageWebView = webView
        (pageAgent as? NetworkTransportRebindDriving)?.resumeAfterTransportRebind()
    }
}

private extension NetworkSession {
    private static func fallbackTransportCapabilities(
        from snapshot: WITransportSupportSnapshot?
    ) -> Set<InspectorTransportCapability> {
        Set(snapshot?.capabilities.compactMap { InspectorTransportCapability(rawValue: $0.rawValue) } ?? [])
    }

    private static func shouldUseTransportDriver(for snapshot: WITransportSupportSnapshot) -> Bool {
        snapshot.isSupported
    }

    private static func makeDefaultPageAgentComponents(
        transportSupportSnapshot: WITransportSupportSnapshot? = nil
    ) -> DefaultPageAgentComponents {
        let preflightSnapshot = transportSupportSnapshot ?? WITransportSession().supportSnapshot
        let pageAgent: any NetworkPageDriving
        let bodyFetcher: any NetworkBodyFetching
        let capabilityProvider: (any InspectorTransportCapabilityProviding)?

        if shouldUseTransportDriver(for: preflightSnapshot) {
            let transportDriver = NetworkTransportDriver()
            pageAgent = transportDriver
            bodyFetcher = transportDriver
            capabilityProvider = transportSupportSnapshot == nil ? transportDriver : nil
        } else {
            let legacyDriver = NetworkLegacyPageDriver()
            pageAgent = legacyDriver
            bodyFetcher = legacyDriver
            capabilityProvider = nil
        }

        return DefaultPageAgentComponents(
            pageAgent: pageAgent,
            bodyFetcher: bodyFetcher,
            transportCapabilityProvider: capabilityProvider,
            transportSupportSnapshot: preflightSnapshot
        )
    }
}

#if DEBUG
extension NetworkSession {
    package func testPageAgentTypeName() -> String {
        String(describing: type(of: pageAgent))
    }
}
#endif

private extension NetworkSession {
    private func cancelAllBodyFetches() {
        let activeKeys = Array(bodyFetchTasks.keys)
        for key in activeKeys {
            cancelBodyFetch(for: key, entry: entry(forID: key.entryID))
        }
    }

    private func cancelBodyFetch(for key: BodyFetchKey, entry: NetworkEntry?) {
        if let activeTask = bodyFetchTasks.removeValue(forKey: key) {
            activeTask.task.cancel()
        }
        guard let entry else {
            return
        }
        resetBodyToInlineIfFetching(for: entry, role: key.role)
    }

    private func clearBodyFetchTask(for key: BodyFetchKey, token: UUID) {
        guard bodyFetchTasks[key]?.token == token else {
            return
        }
        bodyFetchTasks.removeValue(forKey: key)
    }

    private func resetBodyToInlineIfFetching(
        for entry: NetworkEntry,
        role: NetworkBody.Role,
        expectedBody: NetworkBody? = nil
    ) {
        guard let currentBody = body(for: entry, role: role) else {
            return
        }
        if let expectedBody, currentBody !== expectedBody {
            return
        }
        if case .fetching = currentBody.fetchState {
            currentBody.fetchState = .inline
        }
    }

    private func entry(forID id: UUID) -> NetworkEntry? {
        store.entries.first { $0.id == id }
    }

    private func shouldFetch(_ body: NetworkBody) -> Bool {
        switch body.fetchState {
        case .inline:
            return true
        case .fetching, .full, .failed:
            return false
        }
    }

    private func body(for entry: NetworkEntry, role: NetworkBody.Role) -> NetworkBody? {
        switch role {
        case .request:
            return entry.requestBody
        case .response:
            return entry.responseBody
        }
    }
}
