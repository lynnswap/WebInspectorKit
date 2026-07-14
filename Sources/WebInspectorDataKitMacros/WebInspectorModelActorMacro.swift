import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct WebInspectorModelActorMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let actor = declaration.as(ActorDeclSyntax.self) else {
            throw MacroExpansionErrorMessage(
                "@WebInspectorModelActor can only be attached to an actor"
            )
        }

        try validate(actor)

        let access = generatedAccessModifier(for: actor)
        var members: [DeclSyntax] = [
            "\(raw: access)nonisolated let modelActorBinding: WebInspectorModelActorBinding"
        ]

        guard
            actor.memberBlock.members.contains(where: { member in
                member.decl.is(InitializerDeclSyntax.self)
            }) == false
        else {
            return members
        }

        members.append(
            """
            \(raw: access)init(modelContainer: WebInspectorModelContainer) throws {
                self.modelActorBinding = try modelContainer.makeModelActorBinding()
            }
            """
        )
        members.append(
            """
            \(raw: access)init(modelActorBinding: WebInspectorModelActorBinding) {
                self.modelActorBinding = modelActorBinding
            }
            """
        )
        return members
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let actor = declaration.as(ActorDeclSyntax.self) else {
            return []
        }
        guard conflictMessage(for: actor) == nil else { return [] }
        return [
            try ExtensionDeclSyntax("extension \(type.trimmed): WebInspectorModelActor {}")
        ]
    }

    private static func validate(_ actor: ActorDeclSyntax) throws {
        if let message = conflictMessage(for: actor) {
            throw MacroExpansionErrorMessage(message)
        }
    }

    private static func conflictMessage(
        for actor: ActorDeclSyntax
    ) -> String? {
        if actor.inheritanceClause?.inheritedTypes.contains(where: { inherited in
            inherited.type.trimmedDescription == "WebInspectorModelActor"
        }) == true {
            return "@WebInspectorModelActor supplies the WebInspectorModelActor conformance"
        }

        for member in actor.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else {
                continue
            }
            for binding in variable.bindings {
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                    continue
                }
                switch identifier {
                case "modelActorBinding":
                    return "@WebInspectorModelActor owns the stored modelActorBinding"
                case "unownedExecutor":
                    return "@WebInspectorModelActor supplies the actor executor"
                default:
                    continue
                }
            }
        }
        return nil
    }

    private static func generatedAccessModifier(for actor: ActorDeclSyntax) -> String {
        for modifier in actor.modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public):
                return "public "
            case .keyword(.package):
                return "package "
            default:
                continue
            }
        }
        return ""
    }
}

@main
struct WebInspectorDataKitPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        WebInspectorModelActorMacro.self
    ]
}
