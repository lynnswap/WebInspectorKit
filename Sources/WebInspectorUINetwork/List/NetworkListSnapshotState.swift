#if canImport(UIKit)
import WebInspectorDataKit
import UIKit

extension NetworkListViewController {
    @MainActor
    struct SnapshotState {
        struct Application {
            struct ID: Equatable, Sendable {
                fileprivate let rawValue: UInt64
            }

            let id: ID
            let snapshot: NSDiffableDataSourceSnapshot<NetworkListSnapshotSection, NetworkListEntry.ID>
        }

        enum ReceiveResult: Equatable {
            case stale
            case unchanged
            case ready
        }

        enum PrepareResult {
            case none
            case stale
            case apply(Application)
        }

        enum FinishResult: Equatable {
            case stale
            case idle
            case ready
        }

        private struct ReadyArtifact {
            let artifact: NetworkListSnapshotArtifact
        }

        private enum Phase {
            case idle
            case ready(ReadyArtifact)
            case applying(Application.ID, readyArtifact: ReadyArtifact?)
        }

        private(set) var submittedBaseline: NetworkListSnapshotBaseline
        private var phase = Phase.idle

        init() {
            self.init(submittedBaseline: NetworkListSnapshotBaseline(
                generation: 0,
                version: NetworkPanelListVersion(revision: 0, entryIdentityGeneration: 0),
                entryIDs: []
            ))
        }

        init(submittedBaseline: NetworkListSnapshotBaseline) {
            self.submittedBaseline = submittedBaseline
        }

        var isApplying: Bool {
            guard case .applying = phase else {
                return false
            }
            return true
        }

        var hasReadyArtifact: Bool {
            switch phase {
            case .idle:
                false
            case .ready:
                true
            case .applying(_, let readyArtifact):
                readyArtifact != nil
            }
        }

        mutating func receive(
            _ artifact: NetworkListSnapshotArtifact,
            currentVersion: NetworkPanelListVersion
        ) -> ReceiveResult {
            guard isCurrent(artifact, currentVersion: currentVersion) else {
                return preserveCurrentReadyArtifact(currentVersion: currentVersion)
                    ? .ready
                    : .stale
            }

            guard artifact.changeCounts.requiresApply else {
                submittedBaseline = artifact.makeSubmittedBaseline(
                    generation: submittedBaseline.generation
                )
                switch phase {
                case .idle, .ready:
                    phase = .idle
                case .applying(let applicationID, _):
                    phase = .applying(applicationID, readyArtifact: nil)
                }
                return .unchanged
            }

            let readyArtifact = ReadyArtifact(artifact: artifact)
            switch phase {
            case .idle, .ready:
                phase = .ready(readyArtifact)
            case .applying(let applicationID, _):
                phase = .applying(applicationID, readyArtifact: readyArtifact)
            }
            return .ready
        }

        mutating func prepare(
            currentVersion: NetworkPanelListVersion
        ) -> PrepareResult {
            guard case .ready(let readyArtifact) = phase else {
                return .none
            }
            phase = .idle

            let artifact = readyArtifact.artifact
            guard isCurrent(artifact, currentVersion: currentVersion) else {
                return .stale
            }
            precondition(
                submittedBaseline.generation < UInt64.max,
                "Network list snapshot application identity exhausted."
            )
            let applicationID = Application.ID(
                rawValue: submittedBaseline.generation + 1
            )
            submittedBaseline = artifact.makeSubmittedBaseline(
                generation: applicationID.rawValue
            )
            phase = .applying(applicationID, readyArtifact: nil)
            return .apply(Application(id: applicationID, snapshot: artifact.snapshot))
        }

        mutating func finish(_ applicationID: Application.ID) -> FinishResult {
            guard case .applying(let currentApplicationID, let readyArtifact) = phase,
                  currentApplicationID == applicationID else {
                return .stale
            }
            if let readyArtifact {
                phase = .ready(readyArtifact)
                return .ready
            }
            phase = .idle
            return .idle
        }

        @discardableResult
        mutating func discardReadyArtifact() -> Bool {
            switch phase {
            case .idle:
                return false
            case .ready:
                phase = .idle
                return true
            case .applying(let applicationID, let readyArtifact):
                phase = .applying(applicationID, readyArtifact: nil)
                return readyArtifact != nil
            }
        }

        private func isCurrent(
            _ artifact: NetworkListSnapshotArtifact,
            currentVersion: NetworkPanelListVersion
        ) -> Bool {
            artifact.input.target.version == currentVersion
                && artifact.input.baseline.generation == submittedBaseline.generation
                && artifact.input.baseline.version == submittedBaseline.version
        }

        private mutating func preserveCurrentReadyArtifact(
            currentVersion: NetworkPanelListVersion
        ) -> Bool {
            switch phase {
            case .idle:
                return false
            case .ready(let readyArtifact):
                guard isCurrent(
                    readyArtifact.artifact,
                    currentVersion: currentVersion
                ) else {
                    phase = .idle
                    return false
                }
                return true
            case .applying(let applicationID, let readyArtifact):
                guard let readyArtifact else {
                    return false
                }
                guard isCurrent(
                    readyArtifact.artifact,
                    currentVersion: currentVersion
                ) else {
                    phase = .applying(applicationID, readyArtifact: nil)
                    return false
                }
                return true
            }
        }
    }
}
#endif
