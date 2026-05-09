import Foundation
import Observation

package enum NetworkBodySyntaxKind: Hashable, Sendable {
    case plainText
    case json
    case html
    case xml
    case css
    case javascript
}

@Observable
public final class NetworkBody {
    public enum Kind: String, Sendable {
        case text
        case form
        case binary
        case other
    }

    public enum FetchError: Equatable, Sendable {
        case unavailable
        case decodeFailed
        case unknown
    }

    public enum FetchState: Equatable {
        case inline
        case fetching
        case full
        case failed(FetchError)
    }

    public enum Role: CaseIterable {
        case request
        case response
    }

    public struct FormEntry: Sendable {
        public let name: String
        public let value: String
        public let isFile: Bool
        public let fileName: String?

        package init(name: String, value: String, isFile: Bool, fileName: String?) {
            self.name = name
            self.value = value
            self.isFile = isFile
            self.fileName = fileName
        }

    }

    public var kind: Kind {
        didSet {
            refreshTextRepresentation()
        }
    }
    public var preview: String? {
        didSet {
            refreshTextRepresentation()
        }
    }
    public var full: String? {
        didSet {
            refreshTextRepresentation()
        }
    }
    public var size: Int?
    public var isBase64Encoded: Bool {
        didSet {
            refreshTextRepresentation()
        }
    }
    public var isTruncated: Bool
    public var summary: String? {
        didSet {
            refreshTextRepresentation()
        }
    }
    public var reference: String? {
        didSet {
            refreshDeferredLocatorFromExposedFields()
        }
    }
    public var handle: AnyObject? {
        didSet {
            refreshDeferredLocatorFromExposedFields()
        }
    }
    public var formEntries: [FormEntry] {
        didSet {
            refreshTextRepresentation()
        }
    }
    public var fetchState: FetchState
    public var role: Role
    package private(set) var deferredLocator: NetworkDeferredBodyLocator?
    package private(set) var textRepresentation: String?
    package private(set) var textRepresentationSyntaxKind: NetworkBodySyntaxKind
    package private(set) var treatsRawTextAsURLEncodedForm: Bool
    package private(set) var sourceSyntaxKind: NetworkBodySyntaxKind

    @ObservationIgnored
    private var isSynchronizingDeferredLocatorFields = false

    public convenience init(
        kind: Kind = .text,
        preview: String?,
        full: String? = nil,
        size: Int? = nil,
        isBase64Encoded: Bool = false,
        isTruncated: Bool = false,
        summary: String? = nil,
        reference: String? = nil,
        handle: AnyObject? = nil,
        formEntries: [FormEntry] = [],
        fetchState: FetchState? = nil,
        role: Role = .response
    ) {
        self.init(
            kind: kind,
            preview: preview,
            full: full,
            size: size,
            isBase64Encoded: isBase64Encoded,
            isTruncated: isTruncated,
            summary: summary,
            deferredLocator: Self.makeDeferredLocator(reference: reference, handle: handle),
            formEntries: formEntries,
            fetchState: fetchState,
            role: role
        )
    }

    package init(
        kind: Kind = .text,
        preview: String?,
        full: String? = nil,
        size: Int? = nil,
        isBase64Encoded: Bool = false,
        isTruncated: Bool = false,
        summary: String? = nil,
        deferredLocator: NetworkDeferredBodyLocator? = nil,
        formEntries: [FormEntry] = [],
        fetchState: FetchState? = nil,
        role: Role = .response
    ) {
        let resolvedFull = full ?? (isTruncated ? nil : preview)
        let resolvedSize = size ?? (resolvedFull?.count ?? preview?.count)
        self.kind = kind
        self.preview = preview
        self.full = resolvedFull
        self.size = resolvedSize
        self.isBase64Encoded = isBase64Encoded
        self.isTruncated = isTruncated
        self.summary = summary
        self.reference = nil
        self.handle = nil
        self.deferredLocator = deferredLocator
        self.formEntries = formEntries
        self.role = role
        self.textRepresentation = nil
        self.textRepresentationSyntaxKind = .plainText
        self.treatsRawTextAsURLEncodedForm = false
        self.sourceSyntaxKind = .plainText
        if let fetchState {
            self.fetchState = fetchState
        } else if resolvedFull == nil && deferredLocator != nil {
            self.fetchState = .inline
        } else {
            self.fetchState = .full
        }
        syncExposedFieldsFromDeferredLocator()
        refreshTextRepresentation()
    }

    package static func makeDeferredLocator(
        reference: String?,
        handle: AnyObject?,
        preserving currentLocator: NetworkDeferredBodyLocator? = nil
    ) -> NetworkDeferredBodyLocator? {
        if let reference, !reference.isEmpty {
            let targetIdentifier: String?
            if case .networkRequest(_, let currentTargetIdentifier)? = currentLocator {
                targetIdentifier = currentTargetIdentifier
            } else {
                targetIdentifier = nil
            }
            return .networkRequest(id: reference, targetIdentifier: targetIdentifier)
        }
        if let handle {
            return .opaqueHandle(handle)
        }
        if case .pageResource = currentLocator {
            return currentLocator
        }
        return nil
    }

    public var displayText: String? {
        full ?? preview ?? summary
    }

    public var isFetching: Bool {
        if case .fetching = fetchState {
            return true
        }
        return false
    }

    public var hasDeferredContent: Bool {
        deferredLocator != nil
    }

    public func markFetching() {
        fetchState = .fetching
    }

    public func markFailed(_ error: FetchError) {
        fetchState = .failed(error)
    }

    public func applyFullBody(
        _ fullBody: String,
        isBase64Encoded: Bool,
        isTruncated: Bool,
        size: Int?
    ) {
        full = fullBody
        preview = preview ?? fullBody
        self.isBase64Encoded = isBase64Encoded
        self.isTruncated = isTruncated
        self.size = size ?? fullBody.count
        fetchState = .full
    }

    package func applyTextRepresentationHints(
        syntaxKind: NetworkBodySyntaxKind,
        treatsRawTextAsURLEncodedForm: Bool
    ) {
        guard
            sourceSyntaxKind != syntaxKind
                || self.treatsRawTextAsURLEncodedForm != treatsRawTextAsURLEncodedForm
        else {
            return
        }
        sourceSyntaxKind = syntaxKind
        self.treatsRawTextAsURLEncodedForm = treatsRawTextAsURLEncodedForm
        refreshTextRepresentation()
    }

    package func currentDeferredLocator() -> NetworkDeferredBodyLocator? {
        deferredLocator
    }

    package func rebindDeferredTarget(
        from previousTargetIdentifier: String?,
        to targetIdentifier: String?
    ) {
        switch deferredLocator {
        case .pageResource(let currentTargetIdentifier, let frameID, let url)?
            where currentTargetIdentifier == previousTargetIdentifier:
            updateDeferredLocator(
                .pageResource(
                targetIdentifier: targetIdentifier,
                frameID: frameID,
                url: url
            )
            )
        case .networkRequest(let requestID, let currentTargetIdentifier)?
            where currentTargetIdentifier == previousTargetIdentifier:
            updateDeferredLocator(
                .networkRequest(
                id: requestID,
                targetIdentifier: targetIdentifier
            )
            )
        default:
            return
        }
    }

    package func defaultDeferredNetworkRequestTarget(_ targetIdentifier: String?) {
        guard case .networkRequest(let requestID, nil)? = deferredLocator else {
            return
        }
        updateDeferredLocator(
            .networkRequest(
                id: requestID,
                targetIdentifier: targetIdentifier
            )
        )
    }

    package func adoptDeferredNetworkRequestTarget(from other: NetworkBody) {
        guard case .networkRequest(let requestID, let currentTargetIdentifier)? = deferredLocator,
              case .networkRequest(_, let incomingTargetIdentifier)? = other.deferredLocator,
              let incomingTargetIdentifier,
              currentTargetIdentifier != incomingTargetIdentifier else {
            return
        }
        updateDeferredLocator(
            .networkRequest(
                id: requestID,
                targetIdentifier: incomingTargetIdentifier
            )
        )
    }
}

private extension NetworkBody {
    func refreshTextRepresentation() {
        let rawContentText = full ?? preview
        let contentText = decodedContentText() ?? (kind == .binary ? nil : rawContentText)
        let formText = formattedFormText(contentText: contentText)
        let prettyJSON = formText == nil ? Self.prettyPrintedJSON(from: contentText) : nil
        let displayText = formText ?? prettyJSON ?? contentText ?? summary

        let syntaxKind: NetworkBodySyntaxKind
        if kind == .binary || kind == .form || treatsRawTextAsURLEncodedForm {
            syntaxKind = .plainText
        } else if prettyJSON != nil {
            syntaxKind = .json
        } else {
            syntaxKind = sourceSyntaxKind
        }

        if textRepresentation != displayText {
            textRepresentation = displayText
        }
        if textRepresentationSyntaxKind != syntaxKind {
            textRepresentationSyntaxKind = syntaxKind
        }
    }

    func decodedContentText() -> String? {
        guard kind != .binary else {
            return nil
        }
        guard let candidate = full ?? preview else {
            return nil
        }
        guard isBase64Encoded else {
            return candidate
        }
        guard let data = Data(base64Encoded: candidate) else {
            return nil
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }

    func formattedFormText(contentText: String?) -> String? {
        guard kind == .form || treatsRawTextAsURLEncodedForm else {
            return nil
        }
        if formEntries.isEmpty == false {
            return formEntries.map(Self.formEntryLine).joined(separator: "\n")
        }
        guard let contentText else {
            return nil
        }
        return Self.formattedURLEncodedFormText(from: contentText)
    }

    static func formEntryLine(_ entry: FormEntry) -> String {
        let value: String
        if entry.isFile, let fileName = entry.fileName, fileName.isEmpty == false {
            value = "<file \(fileName)>"
        } else {
            value = entry.value
        }
        return "\(entry.name)=\(value)"
    }

    static func formattedURLEncodedFormText(from text: String) -> String? {
        guard text.isEmpty == false, text.contains("=") else {
            return nil
        }

        var lines: [String] = []
        for pair in text.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.isEmpty == false else {
                continue
            }
            guard let name = decodeFormComponent(String(parts[0])) else {
                return nil
            }
            let value: String
            if parts.count > 1 {
                guard let decodedValue = decodeFormComponent(String(parts[1])) else {
                    return nil
                }
                value = decodedValue
            } else {
                value = ""
            }
            lines.append("\(name)=\(value)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func decodeFormComponent(_ component: String) -> String? {
        component
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding
    }

    static func prettyPrintedJSON(from text: String?) -> String? {
        guard let text, let data = text.data(using: .utf8) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        guard
            let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
            let pretty = String(data: prettyData, encoding: .utf8)
        else {
            return nil
        }
        return pretty
    }

    func refreshDeferredLocatorFromExposedFields() {
        guard isSynchronizingDeferredLocatorFields == false else {
            return
        }
        updateDeferredLocator(
            Self.makeDeferredLocator(
            reference: reference,
            handle: handle,
            preserving: deferredLocator
        )
        )
    }

    func syncExposedFieldsFromDeferredLocator() {
        isSynchronizingDeferredLocatorFields = true
        reference = deferredLocator?.reference
        handle = deferredLocator?.handle
        isSynchronizingDeferredLocatorFields = false
    }

    func updateDeferredLocator(_ locator: NetworkDeferredBodyLocator?) {
        let changed = deferredLocator != locator
        deferredLocator = locator
        if changed, case .fetching = fetchState {
            fetchState = .inline
        }
        syncExposedFieldsFromDeferredLocator()
    }
}
