#if canImport(UIKit)
import UIKit
import WebKit

@MainActor
package enum WebInspectorPageAppearance {
    package static func interfaceStyle(
        for color: UIColor?,
        in traitCollection: UITraitCollection
    ) -> UIUserInterfaceStyle {
        guard let color else {
            return .unspecified
        }

        let resolvedColor = color.resolvedColor(with: traitCollection)
        guard let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let convertedColor = resolvedColor.cgColor.converted(
                to: sRGBColorSpace,
                intent: .defaultIntent,
                options: nil
              ),
              let components = convertedColor.components,
              components.count >= 3,
              convertedColor.alpha > 0.01 else {
            return .unspecified
        }

        let red = components[0]
        let green = components[1]
        let blue = components[2]
        let lightness = 0.5 * (max(red, green, blue) + min(red, green, blue))
        return lightness <= 0.5 ? .dark : .light
    }
}

@MainActor
package final class WebInspectorPageAppearanceObserver {
    private weak var webView: WKWebView?
    private let apply: @MainActor (UIUserInterfaceStyle) -> Void
    private var backgroundObservation: NSKeyValueObservation?
    private var traitRegistration: (any UITraitChangeRegistration)?

    package init(
        webView: WKWebView,
        apply: @escaping @MainActor (UIUserInterfaceStyle) -> Void
    ) {
        self.webView = webView
        self.apply = apply
    }

    isolated deinit {
        invalidate()
    }

    package func start() {
        guard let webView else {
            apply(.unspecified)
            return
        }

        backgroundObservation = webView.observe(
            \.underPageBackgroundColor,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.publishCurrentStyle()
            }
        }

        traitRegistration = webView.registerForTraitChanges(
            UITraitCollection.systemTraitsAffectingColorAppearance
        ) { [weak self] (_: WKWebView, _: UITraitCollection) in
            self?.publishCurrentStyle()
        }
    }

    package func invalidate() {
        backgroundObservation?.invalidate()
        backgroundObservation = nil

        if let traitRegistration,
           let webView {
            webView.unregisterForTraitChanges(traitRegistration)
        }
        traitRegistration = nil
    }

    private func publishCurrentStyle() {
        guard let webView else {
            apply(.unspecified)
            return
        }

        apply(
            WebInspectorPageAppearance.interfaceStyle(
                for: webView.underPageBackgroundColor,
                in: webView.traitCollection
            )
        )
    }
}
#endif
