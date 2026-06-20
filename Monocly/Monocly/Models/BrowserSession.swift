import Foundation

enum BrowserSession {}

extension BrowserSession {
    struct Snapshot: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let selectedTabID: UUID
        let tabs: [BrowserSession.TabSnapshot]

        init(
            schemaVersion: Int = BrowserSession.Snapshot.currentSchemaVersion,
            selectedTabID: UUID,
            tabs: [BrowserSession.TabSnapshot]
        ) {
            self.schemaVersion = schemaVersion
            self.selectedTabID = selectedTabID
            self.tabs = tabs
        }
    }

    struct TabSnapshot: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let url: URL
        let title: String?
        let createdAt: Date
        let lastUsedAt: Date
    }

    struct RestoredState: Equatable, Sendable {
        let snapshot: BrowserSession.Snapshot
        let tabStateDataByID: [UUID: Data]
    }

    protocol Storage {
        func load() -> BrowserSession.RestoredState?
        func save(snapshot: BrowserSession.Snapshot, tabStateDataByID: [UUID: Data]) throws
    }

    enum PersistenceMode: Equatable {
        case persistent
        case ephemeral
    }

    struct RestorationPolicy {
        static let `default` = BrowserSession.RestorationPolicy()

        private let shouldRestoreHandler: (BrowserSession.RestoredState) -> Bool
        private let shouldSaveHandler: (BrowserSession.Snapshot) -> Bool

        init(
            shouldRestore: @escaping (BrowserSession.RestoredState) -> Bool = { _ in true },
            shouldSave: @escaping (BrowserSession.Snapshot) -> Bool = { _ in true }
        ) {
            self.shouldRestoreHandler = shouldRestore
            self.shouldSaveHandler = shouldSave
        }

        func shouldRestore(_ restoredState: BrowserSession.RestoredState) -> Bool {
            shouldRestoreHandler(restoredState)
        }

        func shouldSave(_ snapshot: BrowserSession.Snapshot) -> Bool {
            shouldSaveHandler(snapshot)
        }
    }

    struct Persistence {
        private enum Backing {
            case persistent(any BrowserSession.Storage, BrowserSession.RestorationPolicy)
            case ephemeral
        }

        let mode: BrowserSession.PersistenceMode
        private let backing: Backing

        static let ephemeral = BrowserSession.Persistence(mode: .ephemeral)

        static func persistent(
            storage: any BrowserSession.Storage,
            restorationPolicy: BrowserSession.RestorationPolicy = .default
        ) -> BrowserSession.Persistence {
            BrowserSession.Persistence(
                mode: .persistent,
                backing: .persistent(storage, restorationPolicy)
            )
        }

        static func persistent(
            sceneSessionPersistentIdentifier: String
        ) -> BrowserSession.Persistence {
            BrowserSession.Persistence.persistent(
                storage: BrowserSession.FileStorage(
                    sceneSessionPersistentIdentifier: sceneSessionPersistentIdentifier
                )
            )
        }

        static func resolved(
            mode: BrowserSession.PersistenceMode,
            sceneSessionPersistentIdentifier: String
        ) -> BrowserSession.Persistence {
            switch mode {
            case .persistent:
                return .persistent(sceneSessionPersistentIdentifier: sceneSessionPersistentIdentifier)
            case .ephemeral:
                return .ephemeral
            }
        }

        var isPersistent: Bool {
            mode == .persistent
        }

        private init(mode: BrowserSession.PersistenceMode) {
            self.mode = mode
            self.backing = .ephemeral
        }

        private init(
            mode: BrowserSession.PersistenceMode,
            backing: Backing
        ) {
            self.mode = mode
            self.backing = backing
        }

        func restoredState() -> BrowserSession.RestoredState? {
            guard case .persistent(let storage, let restorationPolicy) = backing,
                  let restoredState = storage.load(),
                  restorationPolicy.shouldRestore(restoredState) else {
                return nil
            }
            return restoredState
        }

        func save(snapshot: BrowserSession.Snapshot, tabStateDataByID: [UUID: Data]) throws {
            guard case .persistent(let storage, let restorationPolicy) = backing,
                  restorationPolicy.shouldSave(snapshot) else {
                return
            }
            try storage.save(snapshot: snapshot, tabStateDataByID: tabStateDataByID)
        }
    }
}

extension BrowserSession {
    struct FileStorage: BrowserSession.Storage {
        private struct StoredSnapshot: Codable, Equatable {
            let schemaVersion: Int
            let selectedTabID: UUID
            let tabs: [StoredTabSnapshot]

            init(snapshot: BrowserSession.Snapshot) {
                self.schemaVersion = snapshot.schemaVersion
                self.selectedTabID = snapshot.selectedTabID
                self.tabs = snapshot.tabs.map(StoredTabSnapshot.init(snapshot:))
            }

            var snapshot: BrowserSession.Snapshot {
                BrowserSession.Snapshot(
                    schemaVersion: schemaVersion,
                    selectedTabID: selectedTabID,
                    tabs: tabs.map(\.snapshot)
                )
            }
        }

        private struct StoredTabSnapshot: Codable, Equatable {
            let id: UUID
            let url: URL
            let title: String?
            let createdAt: Date
            let lastUsedAt: Date
            let stateFileName: String

            init(snapshot: BrowserSession.TabSnapshot) {
                self.id = snapshot.id
                self.url = snapshot.url
                self.title = snapshot.title
                self.createdAt = snapshot.createdAt
                self.lastUsedAt = snapshot.lastUsedAt
                self.stateFileName = Self.stateFileName(for: snapshot.id)
            }

            var snapshot: BrowserSession.TabSnapshot {
                BrowserSession.TabSnapshot(
                    id: id,
                    url: url,
                    title: title,
                    createdAt: createdAt,
                    lastUsedAt: lastUsedAt
                )
            }

            static func stateFileName(for id: UUID) -> String {
                "\(id.uuidString).state"
            }
        }

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

        func load() -> BrowserSession.RestoredState? {
            guard let data = try? Data(contentsOf: sessionFileURL),
                  let storedSnapshot = try? decoder.decode(BrowserSession.FileStorage.StoredSnapshot.self, from: data),
                  storedSnapshot.schemaVersion == BrowserSession.Snapshot.currentSchemaVersion,
                  storedSnapshot.tabs.isEmpty == false else {
                return nil
            }

            let tabStateDataByID = storedSnapshot.tabs.reduce(into: [UUID: Data]()) { result, tab in
                let stateURL = tabsDirectoryURL.appendingPathComponent(tab.stateFileName)
                if let data = try? Data(contentsOf: stateURL) {
                    result[tab.id] = data
                }
            }

            return BrowserSession.RestoredState(
                snapshot: storedSnapshot.snapshot,
                tabStateDataByID: tabStateDataByID
            )
        }

        func save(snapshot: BrowserSession.Snapshot, tabStateDataByID: [UUID: Data]) throws {
            try fileManager.createDirectory(at: tabsDirectoryURL, withIntermediateDirectories: true)

            let storedSnapshot = BrowserSession.FileStorage.StoredSnapshot(snapshot: snapshot)
            let validStateFileNames = Set(storedSnapshot.tabs.map(\.stateFileName))
            for tab in storedSnapshot.tabs {
                let stateURL = tabsDirectoryURL.appendingPathComponent(tab.stateFileName)
                guard let stateData = tabStateDataByID[tab.id] else {
                    try? fileManager.removeItem(at: stateURL)
                    continue
                }
                try stateData.write(to: stateURL, options: .atomic)
            }

            try removeStaleStateFiles(retaining: validStateFileNames)

            let sessionData = try encoder.encode(storedSnapshot)
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
}
