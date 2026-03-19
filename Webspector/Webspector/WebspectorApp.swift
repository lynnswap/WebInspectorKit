//
//  WebspectorApp.swift
//  Webspector
//
//  Created by lynnswap on 2025/12/03.
//

import SwiftUI

@main
struct WebspectorApp: App {
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
