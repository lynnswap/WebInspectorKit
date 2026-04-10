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
    private final class WeakSceneBox {
        weak var scene: UIWindowScene?

        init(scene: UIWindowScene) {
            self.scene = scene
        }
    }

    private(set) var currentWindowScene: UIWindowScene?
    private(set) var currentWindow: UIWindow?

    @ObservationIgnored private var sceneRegistry: [String: WeakSceneBox] = [:]
    @ObservationIgnored private var activeSceneIdentifiers: [String] = []
#elseif canImport(AppKit)
    private(set) var currentWindow: NSWindow?
#endif

    private init() {}
}

#if canImport(UIKit)
extension MonoclyWindowContextStore {
    func registerConnectedScene(_ scene: UIWindowScene) {
        sceneRegistry[scene.session.persistentIdentifier] = WeakSceneBox(scene: scene)
        pruneDisconnectedScenes()
    }

    func sceneDidBecomeActive(_ scene: UIWindowScene) {
        let sceneIdentifier = scene.session.persistentIdentifier
        sceneRegistry[sceneIdentifier] = WeakSceneBox(scene: scene)
        activeSceneIdentifiers.removeAll { $0 == sceneIdentifier }
        activeSceneIdentifiers.insert(sceneIdentifier, at: 0)
        setCurrentScene(scene)
    }

    func sceneWillResignActive(_ scene: UIWindowScene) {
        activeSceneIdentifiers.removeAll { $0 == scene.session.persistentIdentifier }
        if currentWindowScene === scene {
            refreshCurrentScene()
        } else if let currentWindowScene {
            currentWindow = Self.preferredWindow(in: currentWindowScene)
        }
    }

    func sceneDidDisconnect(_ scene: UIWindowScene) {
        let sceneIdentifier = scene.session.persistentIdentifier
        sceneRegistry[sceneIdentifier] = nil
        activeSceneIdentifiers.removeAll { $0 == sceneIdentifier }

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
        activeSceneIdentifiers.removeAll()
    }

    func setCurrentSceneForTesting(_ scene: UIWindowScene?, window: UIWindow? = nil) {
        resetForTesting()
        guard let scene else {
            return
        }

        let sceneIdentifier = scene.session.persistentIdentifier
        sceneRegistry[sceneIdentifier] = WeakSceneBox(scene: scene)
        activeSceneIdentifiers = [sceneIdentifier]
        currentWindowScene = scene
        currentWindow = window ?? Self.preferredWindow(in: scene)
    }

    private func setCurrentScene(_ scene: UIWindowScene) {
        currentWindowScene = scene
        currentWindow = Self.preferredWindow(in: scene)
    }

    private func refreshCurrentScene() {
        pruneDisconnectedScenes()

        if let scene = resolvedCurrentScene() {
            setCurrentScene(scene)
            return
        }

        currentWindowScene = nil
        currentWindow = nil
    }

    private func resolvedCurrentScene() -> UIWindowScene? {
        for sceneIdentifier in activeSceneIdentifiers {
            if let scene = sceneRegistry[sceneIdentifier]?.scene,
               scene.activationState == .foregroundActive {
                return scene
            }
        }

        let connectedScenes = sceneRegistry.values.compactMap(\.scene)

        return connectedScenes.first { $0.activationState == .foregroundActive }
            ?? connectedScenes.first { $0.activationState == .foregroundInactive }
    }

    private func pruneDisconnectedScenes() {
        sceneRegistry = sceneRegistry.filter { $0.value.scene != nil }
        activeSceneIdentifiers.removeAll { sceneRegistry[$0]?.scene == nil }
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
