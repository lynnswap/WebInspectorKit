import Foundation
import Observation

enum WINetworkEventKind: String {
    case start
    case response
    case finish
    case fail
    case reset
}

struct WINetworkEventPayload {
    let kind: WINetworkEventKind
    let identifier: String
    let url: String?
    let method: String?
    let statusCode: Int?
    let statusText: String?
    let mimeType: String?
    let requestHeaders: WINetworkHeaders
    let responseHeaders: WINetworkHeaders
    let startTimeSeconds: TimeInterval
    let endTimeSeconds: TimeInterval?
    let wallTimeSeconds: TimeInterval?
    let encodedBodyLength: Int?
    let errorDescription: String?
    let requestType: String?

    init?(dictionary: [String: Any]) {
        guard
            let type = dictionary["type"] as? String,
            let kind = WINetworkEventKind(rawValue: type)
        else {
            return nil
        }
        self.kind = kind
        self.identifier = dictionary["id"] as? String ?? dictionary["requestId"] as? String ?? UUID().uuidString
        self.url = dictionary["url"] as? String
        if let method = dictionary["method"] as? String {
            self.method = method.uppercased()
        } else {
            self.method = nil
        }
        self.statusCode = dictionary["status"] as? Int
        self.statusText = dictionary["statusText"] as? String
        self.mimeType = dictionary["mimeType"] as? String
        self.requestHeaders = WINetworkHeaders(dictionary: dictionary["requestHeaders"] as? [String: String] ?? [:])
        self.responseHeaders = WINetworkHeaders(dictionary: dictionary["responseHeaders"] as? [String: String] ?? [:])

        if let start = dictionary["startTime"] as? Double {
            self.startTimeSeconds = start / 1000.0
        } else {
            self.startTimeSeconds = Date().timeIntervalSince1970
        }
        if let end = dictionary["endTime"] as? Double {
            self.endTimeSeconds = end / 1000.0
        } else {
            self.endTimeSeconds = nil
        }
        if let wallTime = dictionary["wallTime"] as? Double {
            self.wallTimeSeconds = wallTime / 1000.0
        } else {
            self.wallTimeSeconds = nil
        }
        self.encodedBodyLength = dictionary["encodedBodyLength"] as? Int
        if let error = dictionary["error"] as? String, !error.isEmpty {
            self.errorDescription = error
        } else {
            self.errorDescription = nil
        }
        self.requestType = dictionary["requestType"] as? String
    }
}

@Observable
public class WINetworkEntry: Identifiable, Equatable, Hashable {
    
    // Equatable / Hashable
    public static func == (lhs: WINetworkEntry, rhs: WINetworkEntry) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    
    public enum Phase: String {
        case pending
        case completed
        case failed
    }
    
    public let id: String
    public internal(set) var url: String
    public internal(set) var method: String
    public internal(set) var statusCode: Int?
    public internal(set) var statusText: String
    public internal(set) var mimeType: String?
    public internal(set) var requestHeaders: WINetworkHeaders
    public internal(set) var responseHeaders: WINetworkHeaders
    public internal(set) var startTimestamp: TimeInterval
    public internal(set) var endTimestamp: TimeInterval?
    public internal(set) var duration: TimeInterval?
    public internal(set) var encodedBodyLength: Int?
    public internal(set) var errorDescription: String?
    public internal(set) var requestType: String?
    public internal(set) var wallTime: TimeInterval?
    public internal(set) var phase: Phase
    
    init(
        id: String,
        url: String,
        method: String,
        requestHeaders: WINetworkHeaders,
        startTimestamp: TimeInterval,
        wallTime: TimeInterval?
    ) {
        self.id = id
        self.url = url
        self.method = method
        self.requestHeaders = requestHeaders
        self.responseHeaders = WINetworkHeaders()
        self.startTimestamp = startTimestamp
        self.wallTime = wallTime
        self.statusCode = nil
        self.statusText = ""
        self.mimeType = nil
        self.endTimestamp = nil
        self.duration = nil
        self.encodedBodyLength = nil
        self.errorDescription = nil
        self.requestType = nil
        self.phase = .pending
    }

    convenience init(startPayload payload: WINetworkEventPayload) {
        let method = payload.method ?? "GET"
        let url = payload.url ?? ""
        self.init(
            id: payload.identifier,
            url: url,
            method: method,
            requestHeaders: payload.requestHeaders,
            startTimestamp: payload.startTimeSeconds,
            wallTime: payload.wallTimeSeconds
        )
        requestType = payload.requestType
    }

    func applyResponsePayload(_ payload: WINetworkEventPayload) {
        statusCode = payload.statusCode
        statusText = payload.statusText ?? ""
        mimeType = payload.mimeType
        if !payload.responseHeaders.isEmpty {
            responseHeaders = payload.responseHeaders
        }
        if let requestType = payload.requestType {
            self.requestType = requestType
        }
        phase = .pending
    }

    func applyCompletionPayload(_ payload: WINetworkEventPayload, failed: Bool) {
        if let statusCode = payload.statusCode {
            self.statusCode = statusCode
        }
        if let statusText = payload.statusText {
            self.statusText = statusText
        }
        if let mimeType = payload.mimeType {
            self.mimeType = mimeType
        }
        if let encodedBodyLength = payload.encodedBodyLength {
            self.encodedBodyLength = encodedBodyLength
        }
        if let endTime = payload.endTimeSeconds {
            endTimestamp = endTime
            duration = max(0, endTime - startTimestamp)
        }
        if let requestType = payload.requestType {
            self.requestType = requestType
        }
        errorDescription = payload.errorDescription
        phase = failed ? .failed : .completed
        if failed && statusCode == nil {
            statusCode = 0
        }
    }
}

@MainActor
@Observable public final class WINetworkStore {
    public private(set) var isRecording = true
    public private(set) var entries: [WINetworkEntry] = []
    @ObservationIgnored private var indexByID: [String: Int] = [:]

    func applyEvent(_ event: WINetworkEventPayload) {
        switch event.kind {
        case .reset:
            reset()
        case .start:
            handleStart(event)
        case .response:
            handleResponse(event)
        case .finish:
            handleFinish(event, failed: false)
        case .fail:
            handleFinish(event, failed: true)
        }
    }

    func reset() {
        entries.removeAll()
        indexByID.removeAll()
    }

    func clear() {
        reset()
    }

    func setRecording(_ enabled: Bool) {
        isRecording = enabled
    }

    public func entry(for identifier: String?) -> WINetworkEntry? {
        guard let identifier, let index = indexByID[identifier], entries.indices.contains(index) else {
            return nil
        }
        return entries[index]
    }

    private func handleStart(_ event: WINetworkEventPayload) {
        insertOrReplace(WINetworkEntry(startPayload: event))
    }

    private func handleResponse(_ event: WINetworkEventPayload) {
        guard let entry = entry(for: event.identifier) else { return }
        entry.applyResponsePayload(event)
    }

    private func handleFinish(_ event: WINetworkEventPayload, failed: Bool) {
        guard let entry = entry(for: event.identifier) else { return }
        entry.applyCompletionPayload(event, failed: failed)
    }

    private func insertOrReplace(_ entry: WINetworkEntry) {
        if let index = indexByID[entry.id], entries.indices.contains(index) {
            entries[index] = entry
        } else {
            entries.append(entry)
            indexByID[entry.id] = entries.count - 1
        }
    }

}
