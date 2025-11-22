//
//  WIWebView.swift
//  WebInspectorKit
//
//  Created by Codex on 2025/03/04.
//

import WebKit
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class WIWebView: WKWebView {
    convenience init() {
        self.init(frame: .zero, configuration: Self.makeDefaultConfiguration())
    }

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        applyInspectorDefaults()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeDefaultConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    private func applyInspectorDefaults() {
#if DEBUG
        isInspectable = true
#endif

#if canImport(UIKit)
        isOpaque = false
        backgroundColor = .clear
        scrollView.backgroundColor = .clear
        scrollView.isScrollEnabled = true
        scrollView.alwaysBounceVertical = true
#endif
    }
}
