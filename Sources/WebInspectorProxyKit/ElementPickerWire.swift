import Foundation

package func elementPickerModeParametersData(
    enabled: Bool
) throws -> Data {
    var object: [String: Any] = ["enabled": enabled]
    if enabled {
        object["highlightConfig"] = [
            "showInfo": false,
            "contentColor": elementPickerHighlightColor(
                red: 111,
                green: 168,
                blue: 220
            ),
            "paddingColor": elementPickerHighlightColor(
                red: 147,
                green: 196,
                blue: 125
            ),
            "borderColor": elementPickerHighlightColor(
                red: 255,
                green: 229,
                blue: 153
            ),
            "marginColor": elementPickerHighlightColor(
                red: 246,
                green: 178,
                blue: 107
            ),
        ]
    }
    guard JSONSerialization.isValidJSONObject(object) else {
        throw WebInspectorProxyError.commandFailed(
            domain: "DOM",
            method: "setInspectModeEnabled",
            message: "Invalid inspect-mode configuration."
        )
    }
    return try JSONSerialization.data(withJSONObject: object)
}

private func elementPickerHighlightColor(
    red: Int,
    green: Int,
    blue: Int
) -> [String: Any] {
    [
        "r": red,
        "g": green,
        "b": blue,
        "a": 0.66,
    ]
}
