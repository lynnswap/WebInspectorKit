#if canImport(AppKit)
import AppKit
import WebInspectorBridgeObjCShim

@MainActor
public enum WIAppKitBridge {
    public static func menuToolbarControl(from item: NSMenuToolbarItem) -> NSView? {
        WIKRuntimeBridge.menuToolbarControl(from: item)
    }

    public static func window(for view: NSView) -> NSWindow? {
        WIKRuntimeBridge.window(for: view)
    }
}
#endif
