#if canImport(UIKit)
import Synchronization
import UIKit
import WebKit

@MainActor
package enum WebInspectorPageUserInterfaceStyle {
    package static func style(
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
              convertedColor.alpha >= 0.99 else {
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
package final class WebInspectorPageUserInterfaceStyleObserver {
    private weak var webView: WKWebView?
    private let apply: @MainActor (UIUserInterfaceStyle) -> Void
    private var backgroundObservation: NSKeyValueObservation?
    private var traitRegistration: (any UITraitChangeRegistration)?
    private let generation = WebInspectorPageUserInterfaceStyleObserverGeneration()

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

        publishCurrentStyle()

        let generation = self.generation
        backgroundObservation = webView.observe(
            \.underPageBackgroundColor,
            options: [.new]
        ) { [weak self, generation] _, _ in
            guard let self else {
                return
            }
            let scheduledGeneration = generation.current()
            Task { @MainActor [weak self, scheduledGeneration] in
                self?.publishCurrentStyle(ifGeneration: scheduledGeneration)
            }
        }

        traitRegistration = webView.registerForTraitChanges(
            UITraitCollection.systemTraitsAffectingColorAppearance
        ) { [weak self, generation] (_: WKWebView, _: UITraitCollection) in
            guard let self else {
                return
            }
            publishCurrentStyle(ifGeneration: generation.current())
        }
    }

    package func invalidate() {
        generation.advance()
        backgroundObservation?.invalidate()
        backgroundObservation = nil

        if let traitRegistration,
           let webView {
            webView.unregisterForTraitChanges(traitRegistration)
        }
        traitRegistration = nil
    }

    private func publishCurrentStyle(ifGeneration generation: UInt64) {
        guard self.generation.isCurrent(generation) else {
            return
        }
        publishCurrentStyle()
    }

    private func publishCurrentStyle() {
        guard let webView else {
            apply(.unspecified)
            return
        }

        apply(
            WebInspectorPageUserInterfaceStyle.style(
                for: webView.underPageBackgroundColor,
                in: webView.traitCollection
            )
        )
    }
}

private final class WebInspectorPageUserInterfaceStyleObserverGeneration: Sendable {
    private let storage = Mutex<UInt64>(0)

    func current() -> UInt64 {
        storage.withLock { $0 }
    }

    func advance() {
        storage.withLock { generation in
            generation &+= 1
        }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        storage.withLock { current in
            current == generation
        }
    }
}
#endif
