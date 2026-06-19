import UIKit
import WebKit
import OSLog

extension BrowserTabStore {
    @MainActor
    func presentJavaScriptAlert(message: String, webView: WKWebView) async {
        guard let presenter = findPresenter(for: webView) else {
            logger.error("alert presenter not found; ignoring alert")
            return
        }
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "common.ok", bundle: .main), style: .default) { _ in
                continuation.resume()
            })
            presenter.present(alert, animated: true)
        }
    }

    @MainActor
    func presentJavaScriptConfirm(message: String, webView: WKWebView) async -> Bool {
        guard let presenter = findPresenter(for: webView) else {
            logger.error("confirm presenter not found; denying")
            return false
        }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "common.cancel", bundle: .main), style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            alert.addAction(UIAlertAction(title: String(localized: "common.ok", bundle: .main), style: .default) { _ in
                continuation.resume(returning: true)
            })
            presenter.present(alert, animated: true)
        }
    }

    @MainActor
    func presentJavaScriptPrompt(prompt: String, defaultText: String?, webView: WKWebView) async -> String? {
        guard let presenter = findPresenter(for: webView) else {
            logger.error("prompt presenter not found; denying")
            return nil
        }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { textField in
                textField.text = defaultText
            }
            alert.addAction(UIAlertAction(title: String(localized: "common.cancel", bundle: .main), style: .cancel) { _ in
                continuation.resume(returning: nil)
            })
            alert.addAction(UIAlertAction(title: String(localized: "common.ok", bundle: .main), style: .default) { _ in
                continuation.resume(returning: alert.textFields?.first?.text)
            })
            presenter.present(alert, animated: true)
        }
    }

    func findPresenter(for webView: WKWebView) -> UIViewController? {
        var responder: UIResponder? = webView
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController
            }
            responder = nextResponder
        }
        return webView.window?.rootViewController
    }
}
