import SwiftUI

struct SuperClearBackgroundStyle {
}

extension SuperClearBackgroundStyle {
    static var superClear: SuperClearBackgroundStyle {
        SuperClearBackgroundStyle()
    }
}

extension View {
    @ViewBuilder
    func background(_ _: SuperClearBackgroundStyle) -> some View {
        background {
            BackgroundClearView()
        }
    }
}

#if canImport(UIKit)
private struct BackgroundClearView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        InnerView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {
    }

    private final class InnerView: UIView {
        private weak var targetView: UIView?
        private var previousBackgroundColor: UIColor?
        private var didApply = false

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            guard window != nil else {
                return
            }
            applyIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                return
            }
            applyIfNeeded()
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if newWindow == nil {
                restoreIfNeeded()
            }
        }

        private func applyIfNeeded() {
            guard let newTarget = superview?.superview else {
                return
            }
            if targetView !== newTarget {
                restoreIfNeeded()
            }
            guard !didApply else {
                return
            }
            targetView = newTarget
            previousBackgroundColor = newTarget.backgroundColor
            newTarget.backgroundColor = .clear
            didApply = true
        }

        private func restoreIfNeeded() {
            guard didApply else {
                return
            }
            targetView?.backgroundColor = previousBackgroundColor
            targetView = nil
            previousBackgroundColor = nil
            didApply = false
        }
    }
}
#elseif canImport(AppKit)
private struct BackgroundClearView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        InnerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
    }

    private final class InnerView: NSView {
        private weak var targetView: NSView?
        private var previousWantsLayer: Bool?
        private var previousBackgroundColor: CGColor?
        private var didApply = false

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            guard window != nil else {
                return
            }
            applyIfNeeded()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                return
            }
            applyIfNeeded()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                restoreIfNeeded()
            }
        }

        private func applyIfNeeded() {
            guard let newTarget = superview?.superview else {
                return
            }
            if targetView !== newTarget {
                restoreIfNeeded()
            }
            guard !didApply else {
                return
            }
            targetView = newTarget
            previousWantsLayer = newTarget.wantsLayer
            previousBackgroundColor = newTarget.layer?.backgroundColor
            newTarget.wantsLayer = true
            newTarget.layer?.backgroundColor = NSColor.clear.cgColor
            didApply = true
        }

        private func restoreIfNeeded() {
            guard didApply else {
                return
            }
            if let targetView {
                targetView.layer?.backgroundColor = previousBackgroundColor
                if let previousWantsLayer {
                    targetView.wantsLayer = previousWantsLayer
                }
            }
            targetView = nil
            previousWantsLayer = nil
            previousBackgroundColor = nil
            didApply = false
        }
    }
}
#endif
