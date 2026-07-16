#if canImport(UIKit)
import UIKit

@MainActor
package protocol NetworkListProjectionFrameScheduling: AnyObject {
    func schedule(_ action: @escaping @MainActor () -> Void)
    func cancel()
    func invalidate()
}

@MainActor
package final class NetworkListDisplayLinkFrameScheduler: NetworkListProjectionFrameScheduling {
    @MainActor
    private final class Target: NSObject {
        weak var scheduler: NetworkListDisplayLinkFrameScheduler?

        init(scheduler: NetworkListDisplayLinkFrameScheduler) {
            self.scheduler = scheduler
        }

        @objc func displayLinkDidFire(_ displayLink: CADisplayLink) {
            scheduler?.displayLinkDidFire(displayLink)
        }
    }

    private var pendingAction: (@MainActor () -> Void)?
    private lazy var target = Target(scheduler: self)
    private var displayLink: CADisplayLink?

    package init() {}

    package func schedule(_ action: @escaping @MainActor () -> Void) {
        guard pendingAction == nil else {
            return
        }
        pendingAction = action
        let displayLink: CADisplayLink
        if let existingDisplayLink = self.displayLink {
            displayLink = existingDisplayLink
        } else {
            displayLink = CADisplayLink(
                target: target,
                selector: #selector(Target.displayLinkDidFire(_:))
            )
            displayLink.isPaused = true
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }
        displayLink.isPaused = false
    }

    package func cancel() {
        pendingAction = nil
        displayLink?.isPaused = true
    }

    package func invalidate() {
        pendingAction = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        displayLink.isPaused = true
        let action = pendingAction
        pendingAction = nil
        action?()
    }
}
#endif
