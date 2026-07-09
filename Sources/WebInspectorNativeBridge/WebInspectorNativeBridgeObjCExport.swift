// SwiftPM cannot build Swift and ObjC++ sources in one target, so the
// Swift-facing bridge target re-exports the ObjC++ implementation shim.
@_exported import WebInspectorNativeBridgeObjC
