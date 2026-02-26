import ObservationsCompat

enum WIObservationOptions {
    private static let defaultDebounce = ObservationDebounce(
        interval: .milliseconds(80),
        mode: .immediateFirst
    )

    static let debounced = ObservationOptions.debounce(defaultDebounce)
    static let dedupe: ObservationOptions = [.removeDuplicates]
    static let dedupeDebounced: ObservationOptions = [.removeDuplicates, .debounce(defaultDebounce)]
}
