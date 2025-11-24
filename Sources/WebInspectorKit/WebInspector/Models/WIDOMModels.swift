import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

struct WISnapshotPackage {
    let rawJSON: String
}

struct WISubtreePayload: Equatable {
    let rawJSON: String
}

struct WIDOMUpdatePayload: Equatable {
    let rawJSON: String
}

struct WIDOMSelectionSnapshot {
    let nodeId: Int?
    let preview: String
    let attributes: [(name: String, value: String)]
    let path: [String]

    init?(dictionary: [String: Any]) {
        let nodeId = dictionary["id"] as? Int ?? dictionary["nodeId"] as? Int
        let preview = dictionary["preview"] as? String ?? ""
        let attributesPayload = dictionary["attributes"] as? [[String: Any]] ?? []
        let attributes = attributesPayload.compactMap { entry -> (name: String, value: String)? in
            guard let name = entry["name"] as? String else { return nil }
            let value = entry["value"] as? String ?? ""
            return (name: name, value: value)
        }
        let path = dictionary["path"] as? [String] ?? []

        if preview.isEmpty && attributes.isEmpty && path.isEmpty && nodeId == nil {
            return nil
        }

        self.nodeId = nodeId
        self.preview = preview
        self.attributes = attributes
        self.path = path
    }
}

@MainActor
@Observable
public final class WIDOMAttribute {
    public var name: String
    public var value: String {
        didSet {
            applyValueToView()
        }
    }

#if canImport(UIKit)
    @ObservationIgnored public let valueView: SelectionUITextView
#endif

    public init(name: String, value: String) {
        self.name = name
        self.value = value
#if canImport(UIKit)
        self.valueView = SelectionUITextView()
        self.valueView.apply(text: value)
#endif
    }

    private func applyValueToView() {
#if canImport(UIKit)
        valueView.apply(text: value)
#endif
    }
}

@MainActor
@Observable
public final class WIDOMSelection {
    public var nodeId: Int?
    public var preview: String {
        didSet {
            applyPreviewToView()
        }
    }
    public var attributes: [WIDOMAttribute]
    public var path: [String]

#if canImport(UIKit)
    @ObservationIgnored public let previewView: SelectionUITextView
#endif

    public init(
        nodeId: Int?,
        preview: String,
        attributes: [WIDOMAttribute],
        path: [String]
    ) {
        self.nodeId = nodeId
        self.preview = preview
        self.attributes = attributes
        self.path = path
#if canImport(UIKit)
        self.previewView = SelectionUITextView()
        self.previewView.apply(text: preview)
#endif
    }

    private func applyPreviewToView() {
#if canImport(UIKit)
        previewView.apply(text: preview)
#endif
    }

    static func makeOrUpdate(from dictionary: [String: Any], existing: WIDOMSelection?) -> WIDOMSelection? {
        guard let snapshot = WIDOMSelectionSnapshot(dictionary: dictionary) else { return nil }
        let target = existing ?? WIDOMSelection(
            nodeId: snapshot.nodeId,
            preview: snapshot.preview,
            attributes: [],
            path: snapshot.path
        )
        target.nodeId = snapshot.nodeId
        target.preview = snapshot.preview
        target.path = snapshot.path
        target.applyAttributes(snapshot.attributes)
        return target
    }

    private func applyAttributes(_ attributes: [(name: String, value: String)]) {
        if attributes.isEmpty {
            self.attributes = []
            return
        }
        var existingMap = Dictionary(uniqueKeysWithValues: self.attributes.map { ($0.name, $0) })
        var next: [WIDOMAttribute] = []
        for entry in attributes {
            let attribute = existingMap.removeValue(forKey: entry.name) ?? WIDOMAttribute(name: entry.name, value: entry.value)
            attribute.name = entry.name
            attribute.value = entry.value
            next.append(attribute)
        }
        self.attributes = next
    }
}

struct WISelectionResult: Decodable {
    let cancelled: Bool
    let requiredDepth: Int
}
