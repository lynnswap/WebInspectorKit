import Foundation
import WebInspectorCore
import WebInspectorTransport

@MainActor
package protocol NetworkDOMNodeResolving: AnyObject {
    var networkDOMRevision: UInt64 { get }

    func networkCurrentNodeID(
        targetID: ProtocolTarget.ID,
        rawNodeID: DOMNode.ProtocolID
    ) -> DOMNode.ID?

    func networkNode(for nodeID: DOMNode.ID) -> DOMNode?
}

extension DOMSession: NetworkDOMNodeResolving {
    package var networkDOMRevision: UInt64 {
        treeRevision
    }

    package func networkCurrentNodeID(
        targetID: ProtocolTarget.ID,
        rawNodeID: DOMNode.ProtocolID
    ) -> DOMNode.ID? {
        currentNodeID(targetID: targetID, rawNodeID: rawNodeID)
    }

    package func networkNode(for nodeID: DOMNode.ID) -> DOMNode? {
        node(for: nodeID)
    }
}

package struct NetworkByteRange: Equatable, Hashable, Sendable {
    package var start: Int64
    package var end: Int64

    package init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    package var displayLabel: String {
        "Byte Range \(start)-\(end)"
    }

    package static func parse(headers: [String: String]) -> NetworkByteRange? {
        guard let header = NetworkRequest.Display.headerValue(named: "range", in: headers) else {
            return nil
        }
        let trimmedHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedHeader.range(of: "bytes=", options: [.caseInsensitive, .anchored]) != nil else {
            return nil
        }

        let rangeValueStart = trimmedHeader.index(trimmedHeader.startIndex, offsetBy: "bytes=".count)
        let rangeValue = trimmedHeader[rangeValueStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard rangeValue.contains(",") == false else {
            return nil
        }

        let endpoints = rangeValue.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard endpoints.count == 2 else {
            return nil
        }
        let startText = endpoints[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let endText = endpoints[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard startText.isEmpty == false,
              endText.isEmpty == false,
              startText.allSatisfy(\.isNumber),
              endText.allSatisfy(\.isNumber),
              let start = Int64(startText),
              let end = Int64(endText),
              start <= end else {
            return nil
        }
        return NetworkByteRange(start: start, end: end)
    }

    package static func hasByteRangeHeader(_ headers: [String: String]) -> Bool {
        guard let header = NetworkRequest.Display.headerValue(named: "range", in: headers) else {
            return false
        }
        return header.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: "bytes=", options: [.caseInsensitive, .anchored]) != nil
    }
}

package struct NetworkDOMNodeGroup: Equatable, Hashable, Sendable {
    package struct ID: Equatable, Hashable, Sendable {
        package var targetID: ProtocolTarget.ID
        package var rawNodeID: DOMNode.ProtocolID

        package init(targetID: ProtocolTarget.ID, rawNodeID: DOMNode.ProtocolID) {
            self.targetID = targetID
            self.rawNodeID = rawNodeID
        }
    }

    package var id: ID
    package var nodeID: DOMNode.ID?
    package var requestIDs: [NetworkRequest.ID]

    package init(id: ID, nodeID: DOMNode.ID?, requestIDs: [NetworkRequest.ID]) {
        self.id = id
        self.nodeID = nodeID
        self.requestIDs = requestIDs
    }
}

package struct NetworkDisplayEntry: Equatable, Hashable, Identifiable, Sendable {
    package enum ID: Equatable, Hashable, Sendable {
        case resource(NetworkRequest.ID)
        case redirect(NetworkRequest.RedirectHop.ID)
        case domNodeGroup(NetworkDOMNodeGroup.ID)

        package var resourceRequestID: NetworkRequest.ID? {
            switch self {
            case .resource(let id):
                return id
            case .redirect(let id):
                return id.requestKey
            case .domNodeGroup:
                return nil
            }
        }
    }

    package enum Kind: Equatable, Hashable, Sendable {
        case resource(NetworkRequest.ID, indentLevel: Int)
        case redirect(NetworkRequest.RedirectHop.ID, indentLevel: Int)
        case domNodeGroup(NetworkDOMNodeGroup)
    }

    package var kind: Kind

    package init(kind: Kind) {
        self.kind = kind
    }

    package var id: ID {
        switch kind {
        case .resource(let id, _):
            return .resource(id)
        case .redirect(let id, _):
            return .redirect(id)
        case .domNodeGroup(let group):
            return .domNodeGroup(group.id)
        }
    }

    package var requestID: NetworkRequest.ID? {
        id.resourceRequestID
    }
}

package struct NetworkDisplayEntryPresentation: Equatable, Sendable {
    package enum Style: Equatable, Sendable {
        case resource
        case redirect
        case domNodeGroup
    }

    package var displayName: String
    package var secondaryText: String?
    package var statusSeverity: NetworkRequest.Display.StatusSeverity
    package var fileTypeLabel: String
    package var indentLevel: Int
    package var isExpandable: Bool
    package var isExpanded: Bool
    package var style: Style

    package init(
        displayName: String,
        secondaryText: String? = nil,
        statusSeverity: NetworkRequest.Display.StatusSeverity,
        fileTypeLabel: String,
        indentLevel: Int = 0,
        isExpandable: Bool = false,
        isExpanded: Bool = false,
        style: Style
    ) {
        self.displayName = displayName
        self.secondaryText = secondaryText
        self.statusSeverity = statusSeverity
        self.fileTypeLabel = fileTypeLabel
        self.indentLevel = indentLevel
        self.isExpandable = isExpandable
        self.isExpanded = isExpanded
        self.style = style
    }
}

package struct NetworkDisplayRow: Equatable, Sendable {
    package var entry: NetworkDisplayEntry
    package var presentation: NetworkDisplayEntryPresentation

    package init(
        entry: NetworkDisplayEntry,
        presentation: NetworkDisplayEntryPresentation
    ) {
        self.entry = entry
        self.presentation = presentation
    }

    package var id: NetworkDisplayEntry.ID {
        entry.id
    }
}

extension NetworkRequest {
    package var requestedByteRange: NetworkByteRange? {
        NetworkByteRange.parse(headers: request.headers)
    }

    package var hasRequestedByteRangeHeader: Bool {
        NetworkByteRange.hasByteRangeHeader(request.headers)
    }

    package var hasResponseContentRangeHeader: Bool {
        guard let response else {
            return false
        }
        return NetworkRequest.Display.headerValue(named: "content-range", in: response.headers) != nil
    }

    package var hasPartialResponseContent: Bool {
        hasRequestedByteRangeHeader
            || response?.status == 206
            || hasResponseContentRangeHeader
    }
}
