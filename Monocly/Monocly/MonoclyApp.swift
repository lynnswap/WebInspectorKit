//
//  MonoclyApp.swift
//  Monocly
//
//  Created by lynnswap on 2025/12/03.
//

import SwiftUI

@main
struct MonoclyApp: App {
#if canImport(UIKit)
    @UIApplicationDelegateAdaptor(MonoclyAppDelegate.self) private var appDelegate
#elseif canImport(AppKit)
    @NSApplicationDelegateAdaptor(MonoclyAppDelegate.self) private var appDelegate
#endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
#if canImport(UIKit)
        WindowGroup("Web Inspector") {
            BrowserInspectorWindowSceneView()
        }
        .handlesExternalEvents(matching: [BrowserInspectorCoordinator.inspectorWindowSceneActivityType])
#endif
    }
}
