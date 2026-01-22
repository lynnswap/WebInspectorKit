//
//  MiniBrowserApp.swift
//  MiniBrowser
//
//  Created by lynnswap on 2025/12/03.
//

import SwiftUI

@main
struct MiniBrowserApp: App {
    init() {
        IMEUnderlineHook.install()
        WebProcessProxyHook.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.orange)
        }
    }
}
