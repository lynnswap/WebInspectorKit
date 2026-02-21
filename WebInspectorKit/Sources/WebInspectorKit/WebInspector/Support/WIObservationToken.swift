import Observation

final class WIObservationToken: @unchecked Sendable {
    private var isActive = true

    func invalidate() {
        isActive = false
    }

    @MainActor
    func observe(_ apply: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
        guard isActive else { return }
        withObservationTracking({
            apply()
        }, onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else {
                    return
                }
                onChange()
                self.observe(apply, onChange: onChange)
            }
        })
    }
}
