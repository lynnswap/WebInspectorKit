import Foundation
import ObjectiveC
import WebKit

extension BrowserTab {
    enum HistoryDirection {
        case back
        case forward
    }

    struct HistoryMenuItem {
        let backForwardListItem: WKBackForwardListItem
        let title: String
        let subtitle: String
        let direction: BrowserTab.HistoryDirection
    }

    func backHistoryItems(limit: Int = 20) -> [BrowserTab.HistoryMenuItem] {
        historyItems(direction: .back, limit: limit)
    }

    func forwardHistoryItems(limit: Int = 20) -> [BrowserTab.HistoryMenuItem] {
        historyItems(direction: .forward, limit: limit)
    }
}

private extension BrowserTab {
    enum HistorySPI {
        private static func deobfuscate(_ reverseTokens: [String]) -> String {
            reverseTokens.reversed().joined()
        }

        static let browsingContextControllerSelector = NSSelectorFromString(
            deobfuscate(["Controller", "Context", "browsing"])
        )
        static let backForwardListSelector = NSSelectorFromString(
            deobfuscate(["List", "Forward", "back"])
        )
        static let goToBackForwardListItemSelector = NSSelectorFromString(
            deobfuscate([":", "Item", "List", "Forward", "Back", "To", "go"])
        )
        static let setHistoryDelegateSelector = NSSelectorFromString(
            deobfuscate([":", "Delegate", "History", "_set"])
        )
        static let sameDocumentNavigationSelector = NSSelectorFromString(
            deobfuscate([":", "Navigation", "Document", "Same", "did", ":", "navigation", ":", "webView", "_"])
        )
        static let maximumHistoryMenuItemCount = 20
    }

    func historyItems(direction: BrowserTab.HistoryDirection, limit: Int) -> [BrowserTab.HistoryMenuItem] {
        spiHistoryItems(direction: direction, limit: limit).map { item in
            BrowserTab.HistoryMenuItem(
                backForwardListItem: item,
                title: historyTitle(for: item),
                subtitle: item.url.absoluteString,
                direction: direction
            )
        }
    }

    func historyTitle(for item: WKBackForwardListItem) -> String {
        if let title = item.title, title.isEmpty == false {
            return title
        }
        if let host = item.url.host(), host.isEmpty == false {
            return host
        }
        return item.url.absoluteString
    }

    func spiHistoryItems(direction: BrowserTab.HistoryDirection, limit: Int) -> [WKBackForwardListItem] {
        let clampedLimit = max(0, min(limit, HistorySPI.maximumHistoryMenuItemCount))
        guard clampedLimit > 0 else {
            return []
        }

        let backForwardList = spiBackForwardList() ?? webView.backForwardList
        let step = direction == .back ? -1 : 1

        var items: [WKBackForwardListItem] = []
        var offset = step
        while items.count < clampedLimit, let item = backForwardList.item(at: offset) {
            items.append(item)
            offset += step
        }
        return items
    }

    func spiBrowsingContextController() -> NSObject? {
        guard webView.responds(to: HistorySPI.browsingContextControllerSelector),
              let browsingContextController = webView.perform(HistorySPI.browsingContextControllerSelector)?
                .takeUnretainedValue() as? NSObject else {
            return nil
        }
        return browsingContextController
    }

    func spiBackForwardList() -> WKBackForwardList? {
        guard let browsingContextController = spiBrowsingContextController(),
              browsingContextController.responds(to: HistorySPI.backForwardListSelector),
              let backForwardList = browsingContextController.perform(HistorySPI.backForwardListSelector)?
                .takeUnretainedValue() as? WKBackForwardList else {
            return nil
        }
        return backForwardList
    }
}

extension BrowserTab {
    func spiGoToHistoryItem(_ item: WKBackForwardListItem) -> Bool {
        guard let browsingContextController = spiBrowsingContextController(),
              browsingContextController.responds(to: HistorySPI.goToBackForwardListItemSelector) else {
            return false
        }
        browsingContextController.perform(HistorySPI.goToBackForwardListItemSelector, with: item)
        return true
    }

    func configureHistoryDelegateIfAvailable() {
        guard webView.responds(to: HistorySPI.setHistoryDelegateSelector) else {
            return
        }
        webView.perform(HistorySPI.setHistoryDelegateSelector, with: self)
    }

    static func installSameDocumentNavigationDelegateMethodIfNeeded() {
        guard didInstallSameDocumentNavigationDelegateMethod == false else {
            return
        }
        guard let method = class_getInstanceMethod(
            Self.self,
            #selector(handleSameDocumentNavigationBridge(_:navigation:navigationType:))
        ) else {
            return
        }

        class_addMethod(
            Self.self,
            HistorySPI.sameDocumentNavigationSelector,
            method_getImplementation(method),
            method_getTypeEncoding(method)
        )
        didInstallSameDocumentNavigationDelegateMethod = true
    }

    @objc(_webView:backForwardListItemAdded:removed:)
    func _webView(
        _ webView: WKWebView!,
        backForwardListItemAdded itemAdded: WKBackForwardListItem!,
        removed itemsRemoved: [WKBackForwardListItem]!
    ) {
        invalidateHistoryIfNeeded()
        notePersistenceChanged()
    }

    @objc(_webView:didNavigateWithNavigationData:)
    func _webView(_ webView: WKWebView!, didNavigateWith navigationData: NSObject!) {
        invalidateHistoryIfNeeded()
        notePersistenceChanged()
    }

    @objc(_webView:didUpdateHistoryTitle:forURL:)
    func _webView(_ webView: WKWebView!, didUpdateHistoryTitle title: String!, forURL url: URL!) {
        invalidateHistoryIfNeeded()
        notePersistenceChanged()
    }

    @objc(browserTabHandleWebView:navigation:navigationType:)
    func handleSameDocumentNavigationBridge(_ webView: WKWebView!, navigation: WKNavigation!, navigationType: Int64) {
        syncNavigationState(from: webView)
        markWebViewInteractionStateSynchronizedIfNavigationSettled()
    }
}
