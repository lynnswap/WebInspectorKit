/// Failures shared by one-shot fetches and fetched-results registration.
public enum WebInspectorModelContextQueryError: Error, Equatable, Sendable {
    /// The context's schema inventory does not include the requested model.
    case unsupportedModel
    /// The context's persistent-model projection is closing or closed.
    case closed
}

package struct WebInspectorModelFetchOwnerID: Hashable, Sendable {
    let contextIdentity: _WebInspectorModelContextIdentity
    let rawValue: UInt64

    package static func == (
        lhs: WebInspectorModelFetchOwnerID,
        rhs: WebInspectorModelFetchOwnerID
    ) -> Bool {
        lhs.contextIdentity === rhs.contextIdentity
            && lhs.rawValue == rhs.rawValue
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(contextIdentity))
        hasher.combine(rawValue)
    }
}

/// One Core-evaluated identifier snapshot whose records remain stable until
/// the caller owner finishes materializing them.
package final class WebInspectorModelFetchClaim<
    Model: WebInspectorPersistentModel
>: Sendable {
    private let contextCore: WebInspectorModelContextCore
    private let ownerID: WebInspectorModelFetchOwnerID
    private let admission: WebInspectorModelContextOwnerAdmissionGate<
        WebInspectorModelFetchOwnerID
    >

    package let ids: [Model.ID]

    package init(
        contextCore: WebInspectorModelContextCore,
        ownerID: WebInspectorModelFetchOwnerID,
        admission:
            WebInspectorModelContextOwnerAdmissionGate<WebInspectorModelFetchOwnerID>,
        ids: [Model.ID]
    ) {
        self.contextCore = contextCore
        self.ownerID = ownerID
        self.admission = admission
        self.ids = ids
    }

    package var wasAbandoned: Bool {
        admission.currentResolution == .abandoned
    }

    package func complete() async -> WebInspectorModelContextOwnerAdmissionResolution {
        _ = admission.activate()
        return await contextCore.resolveModelFetchAdmission(
            ownerID,
            admission: admission
        )
    }

    package func abandon() async {
        _ = admission.abandon()
        _ = await contextCore.resolveModelFetchAdmission(
            ownerID,
            admission: admission
        )
    }

    deinit {
        _ = admission.abandon()
    }
}
