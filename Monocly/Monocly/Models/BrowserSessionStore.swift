import Foundation

extension BrowserSessionStore {
    struct Snapshot: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let selectedTabID: UUID
        let tabs: [BrowserTabStore.Snapshot]

        init(
            schemaVersion: Int = BrowserSessionStore.Snapshot.currentSchemaVersion,
            selectedTabID: UUID,
            tabs: [BrowserTabStore.Snapshot]
        ) {
            self.schemaVersion = schemaVersion
            self.selectedTabID = selectedTabID
            self.tabs = tabs
        }
    }
}

extension BrowserTabStore {
    struct Snapshot: Codable, Equatable, Identifiable, Sendable {
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
}

extension BrowserSessionStore {
    struct RestoredSession: Sendable {
        let snapshot: BrowserSessionStore.Snapshot
        let tabStateDataByID: [UUID: Data]
    }
}

struct BrowserSessionStore {
    private enum Path {
        static let rootDirectory = "Monocly"
        static let sessionDirectory = "BrowserSession"
        static let sceneSessionsDirectory = "scene-sessions"
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

    init(
        sceneSessionPersistentIdentifier: String,
        browserSessionDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let browserSessionDirectoryURL = browserSessionDirectoryURL
            ?? Self.defaultRootDirectoryURL(fileManager: fileManager)
        let sceneDirectoryURL = browserSessionDirectoryURL
            .appendingPathComponent(Path.sceneSessionsDirectory, isDirectory: true)
            .appendingPathComponent(
                Self.sceneSessionDirectoryName(for: sceneSessionPersistentIdentifier),
                isDirectory: true
            )
        self.init(rootDirectoryURL: sceneDirectoryURL, fileManager: fileManager)
    }

    func load() -> BrowserSessionStore.RestoredSession? {
        guard let data = try? Data(contentsOf: sessionFileURL),
              let snapshot = try? decoder.decode(BrowserSessionStore.Snapshot.self, from: data),
              snapshot.schemaVersion == BrowserSessionStore.Snapshot.currentSchemaVersion,
              snapshot.tabs.isEmpty == false else {
            return nil
        }

        let tabStateDataByID = snapshot.tabs.reduce(into: [UUID: Data]()) { result, tab in
            let stateURL = tabsDirectoryURL.appendingPathComponent(tab.stateFileName)
            if let data = try? Data(contentsOf: stateURL) {
                result[tab.id] = data
            }
        }

        return BrowserSessionStore.RestoredSession(snapshot: snapshot, tabStateDataByID: tabStateDataByID)
    }

    func save(snapshot: BrowserSessionStore.Snapshot, tabStateDataByID: [UUID: Data]) throws {
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

    private static func sceneSessionDirectoryName(for persistentIdentifier: String) -> String {
        let encodedIdentifier = persistentIdentifier.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        guard let encodedIdentifier, encodedIdentifier.isEmpty == false else {
            return "default"
        }
        return encodedIdentifier
    }
}
