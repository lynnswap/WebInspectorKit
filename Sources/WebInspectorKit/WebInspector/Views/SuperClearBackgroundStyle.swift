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
        override func didMoveToWindow() {
            super.didMoveToWindow()
            superview?.superview?.backgroundColor = .clear
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
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let superSuperView = superview?.superview else {
                return
            }
            superSuperView.wantsLayer = true
            superSuperView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
#endif
