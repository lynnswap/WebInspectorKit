import UIKit
import WebKit
import OSLog

@MainActor
protocol BrowserJavaScriptDialogPresenting: AnyObject {
    func presentAlert(
        message: String,
        from presenter: UIViewController,
        completion: @escaping () -> Void
    )

    func presentConfirm(
        message: String,
        from presenter: UIViewController,
        completion: @escaping (Bool) -> Void
    )

    func presentPrompt(
        prompt: String,
        defaultText: String?,
        from presenter: UIViewController,
        completion: @escaping (String?) -> Void
    )
}

@MainActor
final class BrowserJavaScriptDialogPresenter: BrowserJavaScriptDialogPresenting {
    func presentAlert(
        message: String,
        from presenter: UIViewController,
        completion: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", bundle: .main), style: .default) { _ in
            completion()
        })
        presenter.present(alert, animated: true)
    }

    func presentConfirm(
        message: String,
        from presenter: UIViewController,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel", bundle: .main), style: .cancel) { _ in
            completion(false)
        })
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", bundle: .main), style: .default) { _ in
            completion(true)
        })
        presenter.present(alert, animated: true)
    }

    func presentPrompt(
        prompt: String,
        defaultText: String?,
        from presenter: UIViewController,
        completion: @escaping (String?) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = defaultText
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel", bundle: .main), style: .cancel) { _ in
            completion(nil)
        })
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", bundle: .main), style: .default) { _ in
            completion(alert.textFields?.first?.text)
        })
        presenter.present(alert, animated: true)
    }
}

extension BrowserTab {
    @MainActor
    func presentJavaScriptAlert(message: String, webView: WKWebView) async {
        guard let presenter = findPresenter(for: webView) else {
            logger.error("alert presenter not found; ignoring alert")
            return
        }
        await withCheckedContinuation { continuation in
            javaScriptDialogPresenter.presentAlert(message: message, from: presenter) {
                continuation.resume()
            }
        }
    }

    @MainActor
    func presentJavaScriptConfirm(message: String, webView: WKWebView) async -> Bool {
        guard let presenter = findPresenter(for: webView) else {
            logger.error("confirm presenter not found; denying")
            return false
        }
        return await withCheckedContinuation { continuation in
            javaScriptDialogPresenter.presentConfirm(
                message: message,
                from: presenter,
                completion: continuation.resume(returning:)
            )
        }
    }

    @MainActor
    func presentJavaScriptPrompt(prompt: String, defaultText: String?, webView: WKWebView) async -> String? {
        guard let presenter = findPresenter(for: webView) else {
            logger.error("prompt presenter not found; denying")
            return nil
        }
        return await withCheckedContinuation { continuation in
            javaScriptDialogPresenter.presentPrompt(
                prompt: prompt,
                defaultText: defaultText,
                from: presenter,
                completion: continuation.resume(returning:)
            )
        }
    }

    func findPresenter(for webView: WKWebView) -> UIViewController? {
        guard let rootViewController = webView.window?.rootViewController else {
            return nil
        }
        return topVisibleViewController(from: rootViewController)
    }

    private func topVisibleViewController(from viewController: UIViewController) -> UIViewController {
        if let presentedViewController = viewController.presentedViewController {
            return topVisibleViewController(from: presentedViewController)
        }
        if let navigationController = viewController as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return topVisibleViewController(from: visibleViewController)
        }
        if let tabBarController = viewController as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return topVisibleViewController(from: selectedViewController)
        }
        if let splitViewController = viewController as? UISplitViewController,
           let trailingViewController = splitViewController.viewControllers.last {
            return topVisibleViewController(from: trailingViewController)
        }
        return viewController
    }
}
