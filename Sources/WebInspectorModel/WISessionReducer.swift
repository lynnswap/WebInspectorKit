import Foundation
import WebInspectorEngine

public enum WISessionEffect {
    case dom(WIDOMCommand)
    case network(WINetworkCommand)
}

@MainActor
public enum WISessionReducer {
    public static func reduce(state: inout WISessionState, command: WISessionCommand) -> [WISessionEffect] {
        switch command {
        case let .selectTab(tabID):
            state.selectedTabID = tabID
            return []

        case let .dom(command):
            return reduceDOM(command)

        case let .network(command):
            return reduceNetwork(command)
        }
    }

    private static func reduceDOM(_ command: WIDOMCommand) -> [WISessionEffect] {
        switch command {
        case let .setSnapshotDepth(depth):
            let clampedDepth = max(1, depth)
            return [.dom(.setSnapshotDepth(clampedDepth))]

        default:
            return [.dom(command)]
        }
    }

    private static func reduceNetwork(_ command: WINetworkCommand) -> [WISessionEffect] {
        [.network(command)]
    }
}
