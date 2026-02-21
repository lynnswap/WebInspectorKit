import Foundation
import WebKit

@MainActor
public protocol WIPageRuntimeBridge: AnyObject, Sendable {
    var pageWebView: WKWebView? { get }
}

@MainActor
public final class WIWeakPageRuntimeBridge: WIPageRuntimeBridge {
    public weak var pageWebView: WKWebView?

    public init(pageWebView: WKWebView? = nil) {
        self.pageWebView = pageWebView
    }

    public func setPageWebView(_ webView: WKWebView?) {
        pageWebView = webView
    }
}

public struct WIRequiredFeatures: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let dom = WIRequiredFeatures(rawValue: 1 << 0)
    public static let network = WIRequiredFeatures(rawValue: 1 << 1)
}

public struct WIPaneActivation: Hashable, Sendable {
    public var domLiveUpdates: Bool
    public var networkLiveLogging: Bool

    public init(domLiveUpdates: Bool = false, networkLiveLogging: Bool = false) {
        self.domLiveUpdates = domLiveUpdates
        self.networkLiveLogging = networkLiveLogging
    }
}

public struct WIPaneRuntimeDescriptor: Hashable, Sendable {
    public let id: String
    public let requires: WIRequiredFeatures
    public let activation: WIPaneActivation

    public init(id: String, requires: WIRequiredFeatures = [], activation: WIPaneActivation = .init()) {
        self.id = id
        self.requires = requires
        self.activation = activation
    }
}

public enum WISessionLifecycle: String, Sendable {
    case active
    case suspended
    case disconnected
}

public enum WISessionCommand: Sendable {
    case connected
    case suspended
    case disconnected
    case configurePanes([WIPaneRuntimeDescriptor])
    case selectPane(String?)
    case refreshState
    case recoverableError(String)
}

public struct WIDOMViewState: Sendable {
    public var hasAttachedPage: Bool
    public var selectedNodeID: Int?
    public var isAutoSnapshotEnabled: Bool

    public init(
        hasAttachedPage: Bool = false,
        selectedNodeID: Int? = nil,
        isAutoSnapshotEnabled: Bool = false
    ) {
        self.hasAttachedPage = hasAttachedPage
        self.selectedNodeID = selectedNodeID
        self.isAutoSnapshotEnabled = isAutoSnapshotEnabled
    }
}

public struct WINetworkViewState: Sendable {
    public var hasAttachedPage: Bool
    public var mode: NetworkLoggingMode
    public var isRecording: Bool
    public var entryCount: Int

    public init(
        hasAttachedPage: Bool = false,
        mode: NetworkLoggingMode = .stopped,
        isRecording: Bool = false,
        entryCount: Int = 0
    ) {
        self.hasAttachedPage = hasAttachedPage
        self.mode = mode
        self.isRecording = isRecording
        self.entryCount = entryCount
    }
}

public struct WISessionViewState: Sendable {
    public var lifecycle: WISessionLifecycle
    public var selectedPaneID: String?
    public var dom: WIDOMViewState
    public var network: WINetworkViewState
    public var lastRecoverableError: String?

    public init(
        lifecycle: WISessionLifecycle = .disconnected,
        selectedPaneID: String? = nil,
        dom: WIDOMViewState = .init(),
        network: WINetworkViewState = .init(),
        lastRecoverableError: String? = nil
    ) {
        self.lifecycle = lifecycle
        self.selectedPaneID = selectedPaneID
        self.dom = dom
        self.network = network
        self.lastRecoverableError = lastRecoverableError
    }
}

public enum WISessionEvent: Sendable {
    case stateChanged(WISessionViewState)
    case recoverableError(String)
}

public actor WIDOMRuntimeActor {
    private let session: DOMSession

    public init(session: DOMSession) {
        self.session = session
    }

    public func snapshot() async -> WIDOMViewState {
        await MainActor.run {
            WIDOMViewState(
                hasAttachedPage: session.hasPageWebView,
                selectedNodeID: session.selection.nodeId,
                isAutoSnapshotEnabled: session.isAutoSnapshotEnabled
            )
        }
    }
}

public actor WINetworkRuntimeActor {
    private let session: NetworkSession

    public init(session: NetworkSession) {
        self.session = session
    }

    public func snapshot() async -> WINetworkViewState {
        await MainActor.run {
            WINetworkViewState(
                hasAttachedPage: session.hasAttachedPageWebView,
                mode: session.mode,
                isRecording: session.store.isRecording,
                entryCount: session.store.entries.count
            )
        }
    }
}

public actor WIRuntimeActor {
    private let domRuntime: WIDOMRuntimeActor
    private let networkRuntime: WINetworkRuntimeActor
    private let streamStorage: AsyncStream<WISessionEvent>
    private let continuation: AsyncStream<WISessionEvent>.Continuation

    private var lifecycle: WISessionLifecycle = .disconnected
    private var selectedPaneID: String?
    private var panes: [WIPaneRuntimeDescriptor] = []
    private var lastRecoverableError: String?

    public init(domRuntime: WIDOMRuntimeActor, networkRuntime: WINetworkRuntimeActor) {
        self.domRuntime = domRuntime
        self.networkRuntime = networkRuntime

        var captured: AsyncStream<WISessionEvent>.Continuation?
        let stream = AsyncStream<WISessionEvent> { continuation in
            captured = continuation
        }
        self.streamStorage = stream
        self.continuation = captured!
    }

    public func events() -> AsyncStream<WISessionEvent> {
        streamStorage
    }

    public func dispatch(_ command: WISessionCommand) async {
        switch command {
        case .connected:
            lifecycle = .active
            await emitState()

        case .suspended:
            lifecycle = .suspended
            await emitState()

        case .disconnected:
            lifecycle = .disconnected
            selectedPaneID = nil
            await emitState()

        case let .configurePanes(descriptors):
            panes = descriptors
            normalizeSelectedPaneID()
            await emitState()

        case let .selectPane(id):
            if let id {
                if panes.isEmpty || panes.contains(where: { $0.id == id }) {
                    selectedPaneID = id
                } else {
                    selectedPaneID = panes.first?.id
                }
            } else {
                selectedPaneID = nil
            }
            await emitState()

        case .refreshState:
            await emitState()

        case let .recoverableError(message):
            lastRecoverableError = message
            continuation.yield(.recoverableError(message))
            await emitState()
        }
    }

    public func currentState() async -> WISessionViewState {
        let domState = await domRuntime.snapshot()
        let networkState = await networkRuntime.snapshot()
        return WISessionViewState(
            lifecycle: lifecycle,
            selectedPaneID: selectedPaneID,
            dom: domState,
            network: networkState,
            lastRecoverableError: lastRecoverableError
        )
    }
}

private extension WIRuntimeActor {
    func normalizeSelectedPaneID() {
        if panes.isEmpty {
            return
        }
        if let selectedPaneID,
           panes.contains(where: { $0.id == selectedPaneID }) {
            return
        }
        selectedPaneID = panes.first?.id
    }

    func emitState() async {
        let state = await currentState()
        continuation.yield(.stateChanged(state))
    }
}
