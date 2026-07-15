import Observation
import WebInspectorDataKit

@MainActor
@Observable
final class WebInspectorQueryStorage<Model>
where Model: WebInspectorPersistentModel {
    private(set) var fetchedResultsController: WebInspectorFetchedResultsController<Model>?
    private(set) var bindingError: (any Error)?

    @ObservationIgnored private var hasSubmittedBinding = false
    @ObservationIgnored private var desiredContextIdentity: ObjectIdentifier?
    @ObservationIgnored private var attemptedSemanticIdentity: WebInspectorQuerySemanticIdentity?
    @ObservationIgnored private var bindingToken: UInt64 = 0
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?

    init() {}

    isolated deinit {
        lifecycleTask?.cancel()
        fetchedResultsController?.synchronouslyInvalidateRegistration()
    }

    var fetchedObjects: [Model] {
        fetchedResultsController?.fetchedObjects ?? []
    }

    var fetchError: (any Error)? {
        bindingError ?? fetchedResultsController?.fetchError
    }

    var modelContext: WebInspectorModelContext? {
        fetchedResultsController?.modelContext
    }

    func submit(
        container: WebInspectorModelContainer?,
        descriptor: WebInspectorFetchDescriptor<Model>,
        semanticIdentity: WebInspectorQuerySemanticIdentity
    ) {
        guard let container else {
            submitMissingContext(semanticIdentity: semanticIdentity)
            return
        }

        let context = container.mainContext
        let contextIdentity = ObjectIdentifier(context)
        if hasSubmittedBinding,
            desiredContextIdentity == contextIdentity
        {
            guard attemptedSemanticIdentity != semanticIdentity else { return }
            attemptedSemanticIdentity = semanticIdentity
            if let fetchedResultsController {
                refetch(
                    fetchedResultsController,
                    descriptor: descriptor
                )
            } else {
                replaceBinding(
                    context: context,
                    descriptor: descriptor
                )
            }
            return
        }

        hasSubmittedBinding = true
        desiredContextIdentity = contextIdentity
        attemptedSemanticIdentity = semanticIdentity
        replaceBinding(context: context, descriptor: descriptor)
    }

    private func submitMissingContext(
        semanticIdentity: WebInspectorQuerySemanticIdentity
    ) {
        guard
            hasSubmittedBinding == false || desiredContextIdentity != nil
                || attemptedSemanticIdentity != semanticIdentity
        else {
            return
        }

        hasSubmittedBinding = true
        desiredContextIdentity = nil
        attemptedSemanticIdentity = semanticIdentity
        bindingError = WebInspectorQueryError.missingModelContext
        replaceBindingWithMissingContext()
    }

    private func replaceBinding(
        context: WebInspectorModelContext,
        descriptor: WebInspectorFetchDescriptor<Model>
    ) {
        bindingToken &+= 1
        let token = bindingToken
        let previousTask = lifecycleTask
        let previousController = fetchedResultsController
        previousTask?.cancel()
        fetchedResultsController = nil
        bindingError = nil

        lifecycleTask = Task { @MainActor [weak self] in
            await previousTask?.value
            await previousController?.close()
            guard Task.isCancelled == false,
                self?.bindingToken == token
            else {
                return
            }

            let controller = WebInspectorFetchedResultsController(
                fetchDescriptor: descriptor,
                modelContext: context
            )
            do {
                try await controller.performFetch()
            } catch is CancellationError {
                await controller.close()
                return
            } catch {
                // Fetch failure is owned and observed by the controller. It
                // remains registered so a later ready attachment can publish
                // its initial result.
            }

            guard Task.isCancelled == false,
                  let self,
                bindingToken == token
            else {
                await controller.close()
                return
            }
            fetchedResultsController = controller
            bindingError = nil
            lifecycleTask = nil
        }
    }

    private func refetch(
        _ controller: WebInspectorFetchedResultsController<Model>,
        descriptor: WebInspectorFetchDescriptor<Model>
    ) {
        bindingToken &+= 1
        let token = bindingToken
        let previousTask = lifecycleTask
        previousTask?.cancel()
        lifecycleTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard Task.isCancelled == false,
                self?.bindingToken == token
            else {
                return
            }
            do {
                try await controller.refetch(using: descriptor)
            } catch is CancellationError {
                return
            } catch {
                // The FRC retains the last successful objects and exposes the
                // requested descriptor's failure through fetchError.
            }
            guard let self, bindingToken == token else { return }
            lifecycleTask = nil
        }
    }

    private func replaceBindingWithMissingContext() {
        bindingToken &+= 1
        let token = bindingToken
        let previousTask = lifecycleTask
        let previousController = fetchedResultsController
        previousTask?.cancel()
        fetchedResultsController = nil
        lifecycleTask = Task { @MainActor [weak self] in
            await previousTask?.value
            await previousController?.close()
            guard let self, bindingToken == token else { return }
            lifecycleTask = nil
        }
    }
}
