#if canImport(UIKit)
import UIKit

@MainActor
enum WIDOMRuntimeErrorPresenter {
    static func present(
        message: String,
        from sourceItem: UIBarButtonItem,
        in viewController: UIViewController
    ) {
        guard !message.isEmpty else {
            return
        }
        guard viewController.presentedViewController is UIAlertController == false else {
            return
        }

        let alertController = UIAlertController(
            title: nil,
            message: message,
            preferredStyle: .actionSheet
        )
        alertController.addAction(UIAlertAction(title: "OK", style: .cancel))
        alertController.popoverPresentationController?.barButtonItem = sourceItem
        viewController.present(alertController, animated: true)
    }
}
#endif
