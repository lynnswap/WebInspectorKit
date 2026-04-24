import Observation
import WebInspectorEngine

@MainActor
@Observable
public final class V2_WINetworkRuntime {
    public var entries: [NetworkEntry]

    public init(entries: [NetworkEntry] = []) {
        self.entries = entries
    }
}
