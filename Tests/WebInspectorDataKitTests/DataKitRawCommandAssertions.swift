import Foundation
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

enum RawCommandAssertionError: Error, Equatable {
    case missingParameter(String)
    case invalidParameter(String)
}

func commandStringParameter(
    _ command: WebInspectorTestPeer.Command,
    _ key: String
) throws -> String {
    let value = try commandParameter(command, key)
    if let value = value as? String {
        return value
    }
    if let value = value as? NSNumber {
        return value.stringValue
    }
    throw RawCommandAssertionError.invalidParameter(key)
}

func commandIntegerParameter(
    _ command: WebInspectorTestPeer.Command,
    _ key: String
) throws -> Int {
    let value = try commandParameter(command, key)
    guard let number = value as? NSNumber else {
        throw RawCommandAssertionError.invalidParameter(key)
    }
    return number.intValue
}

func commandBooleanParameter(
    _ command: WebInspectorTestPeer.Command,
    _ key: String
) throws -> Bool {
    let value = try commandParameter(command, key)
    guard let number = value as? NSNumber else {
        throw RawCommandAssertionError.invalidParameter(key)
    }
    return number.boolValue
}

func commandNestedStringParameter(
    _ command: WebInspectorTestPeer.Command,
    object objectKey: String,
    key: String
) throws -> String {
    let objectValue = try commandParameter(command, objectKey)
    guard let object = objectValue as? [String: Any], let value = object[key] else {
        throw RawCommandAssertionError.missingParameter("\(objectKey).\(key)")
    }
    if let value = value as? String {
        return value
    }
    if let value = value as? NSNumber {
        return value.stringValue
    }
    throw RawCommandAssertionError.invalidParameter("\(objectKey).\(key)")
}

private func commandParameter(
    _ command: WebInspectorTestPeer.Command,
    _ key: String
) throws -> Any {
    guard let object = try JSONSerialization.jsonObject(
        with: command.parameters.data
    ) as? [String: Any], let value = object[key] else {
        throw RawCommandAssertionError.missingParameter(key)
    }
    return value
}

@MainActor
func createFrameTarget(
    in runtime: DataKitTestRuntime,
    id: String = "frame-test",
    frameID: String = "frame-test"
) async throws -> WebInspectorTarget {
    try await runtime.peer.createTarget(WebInspectorTestPeer.Target(
        id: id,
        type: "frame",
        frameID: frameID,
        parentFrameID: "main-frame"
    ))
    return runtime.proxy.frameTarget(id: WebInspectorTarget.ID(id))
}

func wireTargetID(_ target: WebInspectorTarget) -> String {
    if let pageBindingID = target.pageBindingID {
        return pageBindingID
    }
    switch target.route.storage {
    case let .target(rawValue):
        return rawValue
    case .currentPage:
        preconditionFailure("A current-page test target has no physical page binding.")
    }
}
