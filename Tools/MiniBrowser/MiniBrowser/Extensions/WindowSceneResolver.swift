import SwiftUI

#if canImport(UIKit)
import UIKit
typealias WindowScene = UIWindowScene
#elseif canImport(AppKit)
import AppKit
typealias WindowScene = NSWindow
#endif

private struct WindowSceneKey: EnvironmentKey {
    static var defaultValue: WindowScene?
}

extension EnvironmentValues {
    var windowScene: WindowScene? {
        get { self[WindowSceneKey.self] }
        set { self[WindowSceneKey.self] = newValue }
    }
}

@MainActor
private final class WindowSceneBox {
    weak var windowScene: WindowScene?
}

struct WindowSceneResolverModifier: ViewModifier {
    @State private var box = WindowSceneBox()
    @State private var windowSceneIdentity: ObjectIdentifier?

    func body(content: Content) -> some View {
        content
            .environment(\.windowScene, box.windowScene)
            .background(
                WindowSceneResolver { window in
                    let nextIdentity = window.map(ObjectIdentifier.init)
                    guard windowSceneIdentity != nextIdentity else {
                        return
                    }
                    box.windowScene = window
                    windowSceneIdentity = nextIdentity
                }
            )
    }
}

extension View {
    func resolveWindowScene() -> some View {
        modifier(WindowSceneResolverModifier())
    }
}

#if canImport(UIKit)
private struct WindowSceneResolver: UIViewControllerRepresentable {
    let onResolve: (UIWindowScene?) -> Void

    func makeUIViewController(context: Context) -> ResolverViewController {
        ResolverViewController(onResolve: onResolve)
    }

    func updateUIViewController(_ uiViewController: ResolverViewController, context: Context) {
        uiViewController.onResolve = onResolve
        uiViewController.resolveIfNeeded()
    }

    final class ResolverViewController: UIViewController {
        var onResolve: (UIWindowScene?) -> Void

        init(onResolve: @escaping (UIWindowScene?) -> Void) {
            self.onResolve = onResolve
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            onResolve(view.window?.windowScene)
        }

        func resolveIfNeeded() {
            onResolve(view.window?.windowScene)
        }
    }
}
#elseif canImport(AppKit)
private struct WindowSceneResolver: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ResolverView {
        ResolverView(onResolve: onResolve)
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveIfNeeded()
    }

    final class ResolverView: NSView {
        var onResolve: (NSWindow?) -> Void

        init(onResolve: @escaping (NSWindow?) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onResolve(window)
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            onResolve(window)
        }

        func resolveIfNeeded() {
            onResolve(window)
        }
    }
}
#endif
