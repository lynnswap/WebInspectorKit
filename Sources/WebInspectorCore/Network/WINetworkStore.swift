import Foundation
import Observation
import ObservationBridge
import WebKit

@MainActor
@Observable
public final class WINetworkStore {
    package let session: WINetworkRuntime

    public private(set) weak var selectedEntry: NetworkEntry?

    @ObservationIgnored private var selectedEntryFetchTask: Task<Void, Never>?
    @ObservationIgnored private var selectedEntryObservationHandles: Set<ObservationHandle> = []
    package private(set) var isAttachedToPage: Bool = false

    package init(session: WINetworkRuntime) {
        self.session = session
    }

    isolated deinit {
        selectedEntryFetchTask?.cancel()
        session.detach()
    }

    public var store: NetworkStore {
        session.store
    }

    public var backendSupport: WIBackendSupport {
        session.backendSupport
    }

    package func attach(to webView: WKWebView) {
        session.attach(pageWebView: webView)
        isAttachedToPage = true
        scheduleSelectedEntryBodyFetch()
    }

    package func suspend() {
        selectedEntryFetchTask?.cancel()
        if let selectedEntry {
            session.cancelBodyFetches(for: selectedEntry)
        }
        selectedEntryObservationHandles.removeAll()
        selectedEntry = nil
        session.suspend()
        isAttachedToPage = false
    }

    package func detach() {
        selectedEntryFetchTask?.cancel()
        if let selectedEntry {
            session.cancelBodyFetches(for: selectedEntry)
        }
        selectedEntryObservationHandles.removeAll()
        selectedEntry = nil
        session.detach()
        isAttachedToPage = false
    }

    package func setMode(_ mode: NetworkLoggingMode) {
        guard isAttachedToPage else {
            return
        }
        session.setMode(mode)
    }

    public func selectEntry(_ entry: NetworkEntry?) {
        if let previousSelection = selectedEntry,
           previousSelection.id != entry?.id {
            session.cancelBodyFetches(for: previousSelection)
        }
        selectedEntry = entry
        startObservingSelectedEntry(entry)
        scheduleSelectedEntryBodyFetch()
    }

    public func clear() {
        selectedEntryFetchTask?.cancel()
        if let selectedEntry {
            session.cancelBodyFetches(for: selectedEntry)
        }
        selectedEntryObservationHandles.removeAll()
        selectedEntry = nil
        session.clearNetworkLogs()
    }

    package func requestBodyIfNeeded(for entry: NetworkEntry, role: NetworkBody.Role) {
        session.requestBodyIfNeeded(for: entry, role: role)
    }
}

#if DEBUG
@_spi(PreviewSupport)
extension WINetworkStore {
    package func wiApplyPreviewBatch(_ payload: NSDictionary) {
        session.wiApplyPreviewBatch(payload)
    }
}
#endif

private extension WINetworkStore {
    func startObservingSelectedEntry(_ entry: NetworkEntry?) {
        selectedEntryObservationHandles.removeAll()
        guard let entry else {
            return
        }

        entry.observe([\.requestBody, \.responseBody]) { [weak self, weak entry] in
            guard let self, let entry else {
                return
            }
            guard self.selectedEntry?.id == entry.id else {
                return
            }
            self.scheduleSelectedEntryBodyFetch()
        }
        .store(in: &selectedEntryObservationHandles)
    }

    func scheduleSelectedEntryBodyFetch() {
        selectedEntryFetchTask?.cancel()
        guard isAttachedToPage, let selectedEntry else {
            selectedEntryFetchTask = nil
            return
        }

        let selectedEntryID = selectedEntry.id
        selectedEntryFetchTask = Task { @MainActor [weak self] in
            guard let self, self.isAttachedToPage else {
                return
            }
            guard let selectedEntry = self.selectedEntry, selectedEntry.id == selectedEntryID else {
                return
            }

            if selectedEntry.requestBody != nil {
                self.requestBodyIfNeeded(for: selectedEntry, role: .request)
            }
            guard !Task.isCancelled else {
                return
            }
            guard self.isAttachedToPage else {
                return
            }
            guard let currentSelection = self.selectedEntry, currentSelection.id == selectedEntryID else {
                return
            }
            if currentSelection.responseBody != nil {
                self.requestBodyIfNeeded(for: currentSelection, role: .response)
            }
        }
    }
}
