import ObservationBridge

enum WIObservationOptions {
    private static let defaultThrottle = ObservationThrottle(
        interval: .milliseconds(80),
        mode: .latest
    )

    static let networkListSnapshot: ObservationOptions = [
        .removeDuplicates,
        .rateLimit(.throttle(defaultThrottle))
    ]

    static let domDetailContent = ObservationOptions.rateLimit(.throttle(defaultThrottle))
}
