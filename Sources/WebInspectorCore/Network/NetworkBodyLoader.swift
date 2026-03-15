import Foundation

@MainActor
package final class NetworkBodyLoader {
    private struct BodyFetchKey: Hashable {
        let entryID: UUID
        let role: NetworkBody.Role
    }

    private let bodyFetcher: any NetworkBodyFetching
    private let hasAttachedPageWebView: @MainActor () -> Bool
    private let entryLookup: @MainActor (UUID) -> NetworkEntry?
    private let bodyLookup: @MainActor (NetworkEntry, NetworkBody.Role) -> NetworkBody?

    private var bodyFetchTasks: [BodyFetchKey: (token: UUID, task: Task<Void, Never>)] = [:]

    package init(
        bodyFetcher: any NetworkBodyFetching,
        hasAttachedPageWebView: @escaping @MainActor () -> Bool,
        entryLookup: @escaping @MainActor (UUID) -> NetworkEntry?,
        bodyLookup: @escaping @MainActor (NetworkEntry, NetworkBody.Role) -> NetworkBody?
    ) {
        self.bodyFetcher = bodyFetcher
        self.hasAttachedPageWebView = hasAttachedPageWebView
        self.entryLookup = entryLookup
        self.bodyLookup = bodyLookup
    }

    package func cancelAll() {
        let activeKeys = Array(bodyFetchTasks.keys)
        for key in activeKeys {
            cancelBodyFetch(for: key, entry: entryLookup(key.entryID))
        }
    }

    package func cancelBodyFetches(for entry: NetworkEntry) {
        cancelBodyFetch(for: BodyFetchKey(entryID: entry.id, role: .request), entry: entry)
        cancelBodyFetch(for: BodyFetchKey(entryID: entry.id, role: .response), entry: entry)
    }

    package func requestBodyIfNeeded(for entry: NetworkEntry, role: NetworkBody.Role) {
        guard hasAttachedPageWebView() else {
            return
        }
        guard let body = bodyLookup(entry, role) else {
            return
        }
        guard shouldFetch(body) else {
            return
        }
        guard bodyFetcher.supportsDeferredLoading(for: role) else {
            return
        }

        guard body.deferredLocator != nil else {
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

            guard self.bodyLookup(entry, role) === body else {
                return
            }
            guard self.hasAttachedPageWebView() else {
                self.resetBodyToInlineIfFetching(for: entry, role: role, expectedBody: body)
                return
            }
            guard let locator = body.deferredLocator else {
                body.markFailed(.unavailable)
                return
            }

            let fetchResult = await self.bodyFetcher.fetchBodyResult(locator: locator, role: role)

            guard !Task.isCancelled else {
                self.resetBodyToInlineIfFetching(for: entry, role: role, expectedBody: body)
                return
            }
            guard self.bodyLookup(entry, role) === body else {
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
}

private extension NetworkBodyLoader {
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
        guard let currentBody = bodyLookup(entry, role) else {
            return
        }
        if let expectedBody, currentBody !== expectedBody {
            return
        }
        if case .fetching = currentBody.fetchState {
            currentBody.fetchState = .inline
        }
    }

    private func shouldFetch(_ body: NetworkBody) -> Bool {
        switch body.fetchState {
        case .inline:
            true
        case .fetching, .full, .failed:
            false
        }
    }
}
