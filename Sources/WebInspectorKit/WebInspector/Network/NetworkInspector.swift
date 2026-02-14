import SwiftUI
import Observation
import WebKit
import WebInspectorKitCore

extension WebInspector {
    @MainActor
    @Observable
    public final class NetworkInspector {
        let session: NetworkSession

        public var selectedEntryID: UUID?
        public var navigationPath = NavigationPath()
        public var searchText: String = ""

        public var activeResourceFilters: Set<NetworkResourceFilter> = [] {
            didSet {
                let normalized = NetworkResourceFilter.normalizedSelection(activeResourceFilters)
                if effectiveResourceFilters != normalized {
                    effectiveResourceFilters = normalized
                }
            }
        }

        public private(set) var effectiveResourceFilters: Set<NetworkResourceFilter> = []

        public var sortDescriptors: [SortDescriptor<NetworkEntry>] = [
            SortDescriptor<NetworkEntry>(\.createdAt, order: .reverse),
            SortDescriptor<NetworkEntry>(\.requestID, order: .reverse)
        ]

        init(session: NetworkSession) {
            self.session = session
        }

        public var store: NetworkStore {
            session.store
        }

        public var displayEntries: [NetworkEntry] {
            let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let filteredEntries = store.entries.filter { entry in
                if !effectiveResourceFilters.isEmpty,
                   effectiveResourceFilters.contains(entry.resourceFilter) == false {
                    return false
                }
                if trimmedQuery.isEmpty {
                    return true
                }
                return entry.matchesSearchText(trimmedQuery)
            }
            return filteredEntries.sorted(using: sortDescriptors)
        }

        func attach(to webView: WKWebView) {
            session.attach(pageWebView: webView)
        }

        func suspend() {
            session.suspend()
        }

        func detach() {
            selectedEntryID = nil
            navigationPath = NavigationPath()
            session.detach()
        }

        public func clear() {
            selectedEntryID = nil
            navigationPath = NavigationPath()
            session.clearNetworkLogs()
        }

        public func fetchBodyIfNeeded(
            for entry: NetworkEntry,
            body: NetworkBody,
            force: Bool = false
        ) async {
            if body.fetchState == .fetching {
                return
            }
            if !body.canFetchBody {
                return
            }
            if !force && body.fetchState == .full {
                return
            }

            await fetchBody(for: entry, body: body)
        }

        private func fetchBody(for entry: NetworkEntry, body: NetworkBody) async {
            guard body.fetchState != .fetching else {
                return
            }
            guard let bodyRef = body.reference, !bodyRef.isEmpty else {
                body.markFailed(.unavailable)
                return
            }

            body.markFetching()
            guard let fetched = await session.fetchBody(ref: bodyRef, role: body.role) else {
                body.markFailed(.unavailable)
                return
            }
            applyFetchedBody(fetched, to: body, entry: entry)
        }

        func applyFetchedBody(_ fetched: NetworkBody, to target: NetworkBody, entry: NetworkEntry) {
            if let fullText = fetched.full ?? fetched.preview, !fullText.isEmpty {
                target.applyFullBody(
                    fullText,
                    isBase64Encoded: fetched.isBase64Encoded,
                    isTruncated: fetched.isTruncated,
                    size: fetched.size ?? fullText.count
                )
            }

            // Keep the observable instance stable; update in-place.
            target.summary = fetched.summary ?? target.summary
            target.formEntries = fetched.formEntries
            target.kind = fetched.kind
            target.isTruncated = fetched.isTruncated
            target.isBase64Encoded = fetched.isBase64Encoded
            target.fetchState = .full
            if let size = target.size ?? target.full?.count ?? target.preview?.count {
                target.size = size
            }
            entry.applyFetchedBodySizeMetadata(from: target)
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

        public var tableSelection: Binding<Set<NetworkEntry.ID>> {
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

        func bindingForAllResourceFilters() -> Binding<Bool> {
            Binding(
                get: {
                    self.effectiveResourceFilters.isEmpty
                },
                set: { isOn in
                    if isOn {
                        self.activeResourceFilters.removeAll()
                    }
                }
            )
        }

        func bindingForResourceFilter(_ filter: NetworkResourceFilter) -> Binding<Bool> {
            Binding(
                get: {
                    self.activeResourceFilters.contains(filter)
                },
                set: { isOn in
                    if isOn {
                        self.activeResourceFilters.insert(filter)
                    } else {
                        self.activeResourceFilters.remove(filter)
                    }
                }
            )
        }
    }
}

private extension NetworkEntry {
    func matchesSearchText(_ query: String) -> Bool {
        if query.isEmpty {
            return true
        }
        let candidates = [
            url,
            method,
            statusLabel,
            statusText,
            fileTypeLabel
        ]
        return candidates.contains { $0.localizedStandardContains(query) }
    }
}
