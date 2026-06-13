@preconcurrency import Foundation
import Observation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
@preconcurrency import AppKit
#endif

@MainActor
@Observable
final class MonoclyWindowContextStore {
    static let shared = MonoclyWindowContextStore()

#if canImport(UIKit)
    private final class ConnectedWindowSceneRegistry {
        private final class WeakSceneBox {
            weak var scene: UIWindowScene?

            init(scene: UIWindowScene) {
                self.scene = scene
            }
        }

        private var scenesByIdentifier: [String: WeakSceneBox] = [:]
        private var activeSceneIdentifiers: [String] = []

        func registerConnected(_ scene: UIWindowScene) {
            scenesByIdentifier[scene.session.persistentIdentifier] = WeakSceneBox(scene: scene)
            pruneDisconnectedScenes()
        }

        func markActive(_ scene: UIWindowScene) {
            let sceneIdentifier = scene.session.persistentIdentifier
            scenesByIdentifier[sceneIdentifier] = WeakSceneBox(scene: scene)
            activeSceneIdentifiers.removeAll { $0 == sceneIdentifier }
            activeSceneIdentifiers.insert(sceneIdentifier, at: 0)
        }

        func removeActive(_ scene: UIWindowScene) {
            activeSceneIdentifiers.removeAll { $0 == scene.session.persistentIdentifier }
        }

        func disconnect(_ scene: UIWindowScene) {
            let sceneIdentifier = scene.session.persistentIdentifier
            scenesByIdentifier[sceneIdentifier] = nil
            activeSceneIdentifiers.removeAll { $0 == sceneIdentifier }
        }

        func removeAll() {
            scenesByIdentifier.removeAll()
            activeSceneIdentifiers.removeAll()
        }

        func setOnlyActive(_ scene: UIWindowScene) {
            let sceneIdentifier = scene.session.persistentIdentifier
            scenesByIdentifier = [sceneIdentifier: WeakSceneBox(scene: scene)]
            activeSceneIdentifiers = [sceneIdentifier]
        }

        func resolvedCurrentScene() -> UIWindowScene? {
            pruneDisconnectedScenes()

            for sceneIdentifier in activeSceneIdentifiers {
                if let scene = scenesByIdentifier[sceneIdentifier]?.scene,
                   scene.activationState == .foregroundActive {
                    return scene
                }
            }

            let connectedScenes = scenesByIdentifier.values.compactMap(\.scene)
            return connectedScenes.first { $0.activationState == .foregroundActive }
                ?? connectedScenes.first { $0.activationState == .foregroundInactive }
        }

        private func pruneDisconnectedScenes() {
            scenesByIdentifier = scenesByIdentifier.filter { $0.value.scene != nil }
            activeSceneIdentifiers.removeAll { scenesByIdentifier[$0]?.scene == nil }
        }
    }

    private(set) var currentWindowScene: UIWindowScene?
    private(set) var currentWindow: UIWindow?

    @ObservationIgnored private let sceneRegistry = ConnectedWindowSceneRegistry()
#elseif canImport(AppKit)
    private(set) var currentWindow: NSWindow?
#endif

    private init() {}
}

#if canImport(UIKit)
extension MonoclyWindowContextStore {
    func registerConnectedScene(_ scene: UIWindowScene) {
        sceneRegistry.registerConnected(scene)
    }

    func sceneDidBecomeActive(_ scene: UIWindowScene) {
        sceneRegistry.markActive(scene)
        setCurrentScene(scene)
    }

    func sceneWillResignActive(_ scene: UIWindowScene) {
        sceneRegistry.removeActive(scene)
        if currentWindowScene === scene {
            refreshCurrentScene()
        } else if let currentWindowScene {
            currentWindow = Self.preferredWindow(in: currentWindowScene)
        }
    }

    func sceneDidDisconnect(_ scene: UIWindowScene) {
        sceneRegistry.disconnect(scene)

        if currentWindowScene === scene {
            currentWindowScene = nil
            currentWindow = nil
        }

        refreshCurrentScene()
    }

    func resetForTesting() {
        currentWindowScene = nil
        currentWindow = nil
        sceneRegistry.removeAll()
    }

    func setCurrentSceneForTesting(_ scene: UIWindowScene?, window: UIWindow? = nil) {
        resetForTesting()
        guard let scene else {
            return
        }

        sceneRegistry.setOnlyActive(scene)
        currentWindowScene = scene
        currentWindow = window ?? Self.preferredWindow(in: scene)
    }

    private func setCurrentScene(_ scene: UIWindowScene) {
        currentWindowScene = scene
        currentWindow = Self.preferredWindow(in: scene)
    }

    private func refreshCurrentScene() {
        if let scene = sceneRegistry.resolvedCurrentScene() {
            setCurrentScene(scene)
            return
        }

        currentWindowScene = nil
        currentWindow = nil
    }

    private static func preferredWindow(in scene: UIWindowScene) -> UIWindow? {
        scene.keyWindow
            ?? scene.windows.first(where: \.isKeyWindow)
            ?? scene.windows.first(where: { $0.isHidden == false && $0.alpha > 0 })
            ?? scene.windows.first(where: { $0.isHidden == false })
            ?? scene.windows.first
    }
}

#elseif canImport(AppKit)
extension MonoclyWindowContextStore {
    func noteCurrentWindow(_ window: NSWindow?) {
        currentWindow = window ?? fallbackWindow(excluding: nil)
    }

    func handleClosingWindow(_ window: NSWindow) {
        if currentWindow === window {
            currentWindow = fallbackWindow(excluding: window)
        }

        Task { @MainActor [weak self] in
            self?.refreshCurrentWindow(excluding: window)
        }
    }

    func refreshCurrentWindow(excluding window: NSWindow? = nil) {
        currentWindow = fallbackWindow(excluding: window)
    }

    func resetForTesting() {
        currentWindow = nil
    }

    func setCurrentWindowForTesting(_ window: NSWindow?) {
        currentWindow = window
    }

    func refreshCurrentWindowForTesting(keyWindow: NSWindow?, mainWindow: NSWindow?) {
        currentWindow = keyWindow ?? mainWindow
    }

    private func fallbackWindow(excluding window: NSWindow?) -> NSWindow? {
        if let keyWindow = NSApp.keyWindow, keyWindow !== window {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, mainWindow !== window {
            return mainWindow
        }
        return nil
    }
}
#endif
