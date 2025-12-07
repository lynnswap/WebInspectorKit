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
    let identifier: String?
    let url: String?
    let method: String?
    let statusCode: Int?
    let statusText: String?
    let mimeType: String?
    let requestHeaders: WINetworkHeaders
    let responseHeaders: WINetworkHeaders
    let startTimeSeconds: TimeInterval?
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
        self.identifier = dictionary["id"] as? String ?? dictionary["requestId"] as? String
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
            self.startTimeSeconds = nil
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

public struct WINetworkEntry: Identifiable, Hashable {
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
    public internal(set) var startTimestamp: TimeInterval?
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
        startTimestamp: TimeInterval?,
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
        guard let id = event.identifier else { return }
        let method = event.method ?? "GET"
        let url = event.url ?? ""
        var entry = WINetworkEntry(
            id: id,
            url: url,
            method: method,
            requestHeaders: event.requestHeaders,
            startTimestamp: event.startTimeSeconds,
            wallTime: event.wallTimeSeconds
        )
        entry.requestType = event.requestType
        insertOrReplace(entry)
    }

    private func handleResponse(_ event: WINetworkEventPayload) {
        guard let id = event.identifier, var entry = entry(for: id) else { return }
        entry.statusCode = event.statusCode
        entry.statusText = event.statusText ?? ""
        entry.mimeType = event.mimeType
        if !event.responseHeaders.isEmpty {
            entry.responseHeaders = event.responseHeaders
        }
        entry.phase = .pending
        update(entry)
    }

    private func handleFinish(_ event: WINetworkEventPayload, failed: Bool) {
        guard let id = event.identifier, var entry = entry(for: id) else { return }
        entry.statusCode = event.statusCode ?? entry.statusCode
        entry.statusText = event.statusText ?? entry.statusText
        entry.mimeType = event.mimeType ?? entry.mimeType
        entry.encodedBodyLength = event.encodedBodyLength ?? entry.encodedBodyLength
        entry.endTimestamp = event.endTimeSeconds ?? entry.endTimestamp
        if let start = entry.startTimestamp, let end = entry.endTimestamp {
            entry.duration = max(0, end - start)
        }
        entry.errorDescription = event.errorDescription
        entry.requestType = event.requestType ?? entry.requestType
        entry.phase = failed ? .failed : .completed
        if failed && entry.statusCode == nil {
            entry.statusCode = 0
        }
        update(entry)
    }

    private func insertOrReplace(_ entry: WINetworkEntry) {
        if let index = indexByID[entry.id], entries.indices.contains(index) {
            entries[index] = entry
        } else {
            entries.append(entry)
            indexByID[entry.id] = entries.count - 1
        }
    }

    private func update(_ entry: WINetworkEntry) {
        guard let index = indexByID[entry.id], entries.indices.contains(index) else { return }
        entries[index] = entry
    }
}
