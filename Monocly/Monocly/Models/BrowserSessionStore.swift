import Foundation

struct BrowserSessionSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let selectedTabID: UUID
    let tabs: [BrowserTabSnapshot]

    init(
        schemaVersion: Int = BrowserSessionSnapshot.currentSchemaVersion,
        selectedTabID: UUID,
        tabs: [BrowserTabSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.selectedTabID = selectedTabID
        self.tabs = tabs
    }
}

struct BrowserTabSnapshot: Codable, Equatable, Identifiable {
    let id: UUID
    let url: URL
    let title: String?
    let createdAt: Date
    let lastUsedAt: Date
    let stateFileName: String

    static func stateFileName(for id: UUID) -> String {
        "\(id.uuidString).state"
    }
}

struct BrowserRestoredSession {
    let snapshot: BrowserSessionSnapshot
    let tabStateDataByID: [UUID: Data]
}

struct BrowserSessionStore {
    private enum Path {
        static let rootDirectory = "Monocly"
        static let sessionDirectory = "BrowserSession"
        static let tabsDirectory = "tabs"
        static let sessionFile = "session.json"
    }

    let rootDirectoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        rootDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.rootDirectoryURL = rootDirectoryURL ?? Self.defaultRootDirectoryURL(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func load() -> BrowserRestoredSession? {
        guard let data = try? Data(contentsOf: sessionFileURL),
              let snapshot = try? decoder.decode(BrowserSessionSnapshot.self, from: data),
              snapshot.schemaVersion == BrowserSessionSnapshot.currentSchemaVersion,
              snapshot.tabs.isEmpty == false else {
            return nil
        }

        let tabStateDataByID = snapshot.tabs.reduce(into: [UUID: Data]()) { result, tab in
            let stateURL = tabsDirectoryURL.appendingPathComponent(tab.stateFileName)
            if let data = try? Data(contentsOf: stateURL) {
                result[tab.id] = data
            }
        }

        return BrowserRestoredSession(snapshot: snapshot, tabStateDataByID: tabStateDataByID)
    }

    func save(snapshot: BrowserSessionSnapshot, tabStateDataByID: [UUID: Data]) throws {
        try fileManager.createDirectory(at: tabsDirectoryURL, withIntermediateDirectories: true)

        let validStateFileNames = Set(snapshot.tabs.map(\.stateFileName))
        for tab in snapshot.tabs {
            let stateURL = tabsDirectoryURL.appendingPathComponent(tab.stateFileName)
            guard let stateData = tabStateDataByID[tab.id] else {
                try? fileManager.removeItem(at: stateURL)
                continue
            }
            try stateData.write(to: stateURL, options: .atomic)
        }

        try removeStaleStateFiles(retaining: validStateFileNames)

        let sessionData = try encoder.encode(snapshot)
        try sessionData.write(to: sessionFileURL, options: .atomic)
    }

    private var sessionFileURL: URL {
        rootDirectoryURL.appendingPathComponent(Path.sessionFile)
    }

    private var tabsDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent(Path.tabsDirectory, isDirectory: true)
    }

    private func removeStaleStateFiles(retaining validStateFileNames: Set<String>) throws {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: tabsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for fileURL in contents where validStateFileNames.contains(fileURL.lastPathComponent) == false {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private static func defaultRootDirectoryURL(fileManager: FileManager) -> URL {
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupportURL
            .appendingPathComponent(Path.rootDirectory, isDirectory: true)
            .appendingPathComponent(Path.sessionDirectory, isDirectory: true)
    }
}
