import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
@testable import WebInspectorDataKitMacros

private let modelActorMacros: [String: Macro.Type] = [
    "WebInspectorModelActor": WebInspectorModelActorMacro.self
]

@Test
func modelActorMacroAddsOneRetainedBindingAndInitializers() {
    assertMacroExpansion(
        """
        @WebInspectorModelActor
        public actor ExportWorker {}
        """,
        expandedSource: """
            public actor ExportWorker {

                public nonisolated let modelActorBinding: WebInspectorModelActorBinding

                public init(modelContainer: WebInspectorModelContainer) throws {
                    self.modelActorBinding = try modelContainer.makeModelActorBinding()
                }

                public init(modelActorBinding: WebInspectorModelActorBinding) {
                    self.modelActorBinding = modelActorBinding
                }
            }

            extension ExportWorker: WebInspectorModelActor {
            }
            """,
        macros: modelActorMacros
    )
}

@Test
func modelActorMacroLeavesCustomInitializationToDefiniteInitialization() {
    assertMacroExpansion(
        """
        @WebInspectorModelActor
        actor ExportWorker {
            init(container: WebInspectorModelContainer) throws {
                modelActorBinding = try container.makeModelActorBinding()
            }
        }
        """,
        expandedSource: """
            actor ExportWorker {
                init(container: WebInspectorModelContainer) throws {
                    modelActorBinding = try container.makeModelActorBinding()
                }

                nonisolated let modelActorBinding: WebInspectorModelActorBinding
            }

            extension ExportWorker: WebInspectorModelActor {
            }
            """,
        macros: modelActorMacros
    )
}

@Test
func modelActorMacroRejectsNonActorAttachment() {
    assertMacroExpansion(
        """
        @WebInspectorModelActor
        struct ExportWorker {}
        """,
        expandedSource: """
            struct ExportWorker {}
            """,
        diagnostics: [
            DiagnosticSpec(
                message: "@WebInspectorModelActor can only be attached to an actor",
                line: 1,
                column: 1
            )
        ],
        macros: modelActorMacros
    )
}

@Test
func modelActorMacroRejectsConflictingExecutorStorage() {
    assertMacroExpansion(
        """
        @WebInspectorModelActor
        actor ExportWorker {
            nonisolated let unownedExecutor: UnownedSerialExecutor
        }
        """,
        expandedSource: """
            actor ExportWorker {
                nonisolated let unownedExecutor: UnownedSerialExecutor
            }
            """,
        diagnostics: [
            DiagnosticSpec(
                message: "@WebInspectorModelActor supplies the actor executor",
                line: 1,
                column: 1
            )
        ],
        macros: modelActorMacros
    )
}
