import WebKit
import SwiftUI
import Observation

@MainActor
@Observable
public final class WINetworkViewModel {
    public let session: WINetworkSession
    public var selectedEntryID: UUID?
    public var store: WINetworkStore {
        session.store
    }
    public var sortDescriptors: [SortDescriptor<WINetworkEntry>] = [
        SortDescriptor<WINetworkEntry>(\.createdAt, order: .reverse),
        SortDescriptor<WINetworkEntry>(\.requestID, order: .reverse)
    ]
    public var displayEntries: [WINetworkEntry] {
        store.entries.sorted(using: sortDescriptors)
    }

    public init(session: WINetworkSession = WINetworkSession()) {
        self.session = session
    }

    public func attach(to webView: WKWebView) {
        session.attach(pageWebView: webView)
    }

    public func setRecording(_ enabled: Bool) {
        session.setRecording(enabled)
    }

    public func clearNetworkLogs() {
        selectedEntryID = nil
        session.clearNetworkLogs()
    }

    public func suspend() {
        session.suspend()
    }

    public func detach() {
        session.detach()
    }

    public var isShowingDetail: Binding<Bool> {
        Binding(
            get: { self.selectedEntryID != nil },
            set: { newValue in
                if !newValue {
                    self.selectedEntryID = nil
                }
            }
        )
    }

    public var tableSelection: Binding<Set<WINetworkEntry.ID>> {
        Binding(
            get: {
                guard let selectedEntryID = self.selectedEntryID else {
                    return Set()
                }
                return Set([selectedEntryID])
            },
            set: { newSelection in
                self.selectedEntryID = newSelection.first
            }
        )
    }
}
