import Dispatch

/// One container-issued context plus the sole serial queue used by its model
/// actor. Runtime fields stay internal so sibling targets cannot extract a
/// non-Sendable context or establish a second scheduling path.
public final class WebInspectorModelActorBinding: @unchecked Sendable {
    internal let modelContext: WebInspectorModelContext
    internal let serialQueue: DispatchSerialQueue

    internal init(
        modelContext: WebInspectorModelContext,
        serialQueue: DispatchSerialQueue
    ) {
        self.modelContext = modelContext
        self.serialQueue = serialQueue
    }

    deinit {
        modelContext.lifecycle.synchronouslyInvalidateDormantIssuance()
    }
}

@attached(
    member,
    names: named(modelActorBinding), named(init)
)
@attached(
    extension,
    conformances: WebInspectorModelActor
)
public macro WebInspectorModelActor() =
    #externalMacro(
        module: "WebInspectorDataKitMacros",
        type: "WebInspectorModelActorMacro"
    )

/// A model actor whose context and custom executor share one issued binding.
public protocol WebInspectorModelActor: Actor {
    nonisolated var modelActorBinding: WebInspectorModelActorBinding { get }
}

extension WebInspectorModelActor {
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        modelActorBinding.serialQueue.asUnownedSerialExecutor()
    }

    public var modelContext: WebInspectorModelContext {
        modelActorBinding.modelContext
    }

    public nonisolated var modelContainer: WebInspectorModelContainer {
        modelActorBinding.modelContext.container
    }

    public func closeModelContext() async {
        await modelContext.close()
    }
}
