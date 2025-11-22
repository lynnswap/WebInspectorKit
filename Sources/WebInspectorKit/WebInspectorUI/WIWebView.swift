//
//  WIWebView.swift
//  WebInspectorKit
//
//  Created by Codex on 2025/03/04.
//

import WebKit

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
        configuration.writingToolsBehavior = .none
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
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        
        guard builder.system == .context else { return }
        
        builder.remove(menu: .standardEdit)
        builder.remove(menu: .lookup)
        builder.remove(menu: .share)
        
        let action = UIAction(
            title: "Custom Menu"
        ) { [weak self] _ in
            
        }
        
        let menu = UIMenu(
            title: "",
            image: nil,
            identifier: UIMenu.Identifier("com.example.custom-edit"),
            options: [.displayInline],
            children: [action]
        )
        
        builder.insertChild(menu, atStartOfMenu: .root)
    }
}
