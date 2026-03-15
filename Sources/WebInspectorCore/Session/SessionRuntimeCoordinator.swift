import Combine
import WebKit

@MainActor
package final class SessionRuntimeCoordinator {
    private let rebindClock: any Clock<Duration>

    private weak var connectedPageWebView: WKWebView?
    private var pageLoadingObservation: AnyCancellable?
    private var lastObservedPageLoading: Bool?
    private var navigationRebindPrepared = false
    private var navigationRebindTask: Task<Void, Never>?

    package init(rebindClock: any Clock<Duration>) {
        self.rebindClock = rebindClock
    }

    package var pageWebView: WKWebView? {
        connectedPageWebView
    }

    package func setPageWebView(
        _ webView: WKWebView?,
        onPageLoadingChange: @escaping @MainActor (Bool) -> Void
    ) {
        if connectedPageWebView !== webView {
            stopObservingPageLoading()
            resetNavigationRebindState()
        }
        connectedPageWebView = webView
        guard let webView else {
            return
        }
        startObservingPageLoading(on: webView, onPageLoadingChange: onPageLoadingChange)
    }

    package func activateIfPossible(
        lifecycle: WISessionLifecycle,
        runtimeState: SessionActivationPlan.RuntimeAttachmentState,
        usesNavigationAwareRebind: Bool,
        domStore: WIDOMStore,
        networkStore: WINetworkStore,
        onRecoverableError: @escaping @MainActor (String) -> Void,
        onPageLoadingChange: @escaping @MainActor (Bool) -> Void
    ) {
        guard let connectedPageWebView else {
            return
        }
        startObservingPageLoading(on: connectedPageWebView, onPageLoadingChange: onPageLoadingChange)
        if usesNavigationAwareRebind, connectedPageWebView.isLoading {
            prepareForNavigationRebindIfNeeded(
                runtimeState: runtimeState,
                domStore: domStore,
                onRecoverableError: onRecoverableError
            )
        }
        apply(
            runtimeState: runtimeState,
            lifecycle: lifecycle,
            domStore: domStore,
            networkStore: networkStore
        )
    }

    package func handlePageLoadingStateChange(
        _ isLoading: Bool,
        usesNavigationAwareRebind: Bool,
        currentRuntimeState: @escaping @MainActor () -> SessionActivationPlan.RuntimeAttachmentState,
        domStore: WIDOMStore,
        onRecoverableError: @escaping @MainActor (String) -> Void
    ) {
        let previousLoading = lastObservedPageLoading
        lastObservedPageLoading = isLoading

        guard usesNavigationAwareRebind else {
            return
        }

        guard let previousLoading else {
            if isLoading {
                prepareForNavigationRebindIfNeeded(
                    runtimeState: currentRuntimeState(),
                    domStore: domStore,
                    onRecoverableError: onRecoverableError
                )
            }
            return
        }
        guard previousLoading != isLoading else {
            return
        }

        if isLoading {
            prepareForNavigationRebindIfNeeded(
                runtimeState: currentRuntimeState(),
                domStore: domStore,
                onRecoverableError: onRecoverableError
            )
        } else {
            resumeAfterNavigationRebindIfNeeded(
                currentRuntimeState: currentRuntimeState,
                domStore: domStore,
                onRecoverableError: onRecoverableError
            )
        }
    }

    package func apply(
        runtimeState: SessionActivationPlan.RuntimeAttachmentState,
        lifecycle: WISessionLifecycle,
        domStore: WIDOMStore,
        networkStore: WINetworkStore
    ) {
        if lifecycle == .suspended {
            domStore.suspend()
            networkStore.suspend()
            return
        }

        if navigationRebindPrepared, connectedPageWebView?.isLoading == true {
            if runtimeState.domEnabled {
                domStore.session.prepareForNavigationReconnect()
            } else {
                domStore.suspend()
            }

            if let webView = connectedPageWebView {
                if runtimeState.networkEnabled {
                    networkStore.attach(to: webView)
                } else {
                    networkStore.suspend()
                }
            } else if runtimeState.networkEnabled == false || lifecycle != .disconnected {
                networkStore.suspend()
            }

            domStore.setAutoSnapshotEnabled(runtimeState.domEnabled && runtimeState.domAutoSnapshotEnabled)
            networkStore.setMode(runtimeState.networkEnabled ? runtimeState.networkMode : .buffering)
            return
        }

        if let webView = connectedPageWebView {
            if runtimeState.domEnabled {
                domStore.attach(to: webView)
            } else {
                domStore.suspend()
            }

            if runtimeState.networkEnabled {
                networkStore.attach(to: webView)
            } else {
                networkStore.suspend()
            }
        } else {
            if runtimeState.domEnabled == false || lifecycle != .disconnected {
                domStore.suspend()
            }
            if runtimeState.networkEnabled == false || lifecycle != .disconnected {
                networkStore.suspend()
            }
        }

        domStore.setAutoSnapshotEnabled(runtimeState.domEnabled && runtimeState.domAutoSnapshotEnabled)
        networkStore.setMode(runtimeState.networkEnabled ? runtimeState.networkMode : .buffering)
    }

    package func suspend(domStore: WIDOMStore, networkStore: WINetworkStore) {
        navigationRebindTask?.cancel()
        navigationRebindTask = nil
        stopObservingPageLoading()
        resetNavigationRebindState()
        domStore.suspend()
        networkStore.suspend()
    }

    package func disconnect(domStore: WIDOMStore, networkStore: WINetworkStore) {
        navigationRebindTask?.cancel()
        navigationRebindTask = nil
        stopObservingPageLoading()
        connectedPageWebView = nil
        resetNavigationRebindState()
        domStore.detach()
        networkStore.detach()
    }

    package func tearDown(domStore: WIDOMStore, networkStore: WINetworkStore) {
        navigationRebindTask?.cancel()
        pageLoadingObservation?.cancel()
        domStore.detach()
        networkStore.detach()
    }
}

private extension SessionRuntimeCoordinator {
    func startObservingPageLoading(
        on webView: WKWebView,
        onPageLoadingChange: @escaping @MainActor (Bool) -> Void
    ) {
        guard pageLoadingObservation == nil else {
            return
        }

        pageLoadingObservation = webView.publisher(for: \.isLoading, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak webView] isLoading in
                guard let self, let webView else {
                    return
                }
                guard self.connectedPageWebView === webView else {
                    return
                }
                onPageLoadingChange(isLoading)
            }
    }

    func stopObservingPageLoading() {
        pageLoadingObservation?.cancel()
        pageLoadingObservation = nil
        lastObservedPageLoading = nil
    }

    func resetNavigationRebindState() {
        navigationRebindPrepared = false
    }

    func prepareForNavigationRebindIfNeeded(
        runtimeState: SessionActivationPlan.RuntimeAttachmentState,
        domStore: WIDOMStore,
        onRecoverableError: @escaping @MainActor (String) -> Void
    ) {
        guard runtimeState.domEnabled else {
            return
        }

        navigationRebindTask?.cancel()
        navigationRebindTask = nil
        domStore.session.prepareForNavigationReconnect()
        navigationRebindPrepared = true
        scheduleNavigationRebindResume(
            currentRuntimeState: { runtimeState },
            domStore: domStore,
            onRecoverableError: onRecoverableError
        )
    }

    func resumeAfterNavigationRebindIfNeeded(
        currentRuntimeState: @escaping @MainActor () -> SessionActivationPlan.RuntimeAttachmentState,
        domStore: WIDOMStore,
        onRecoverableError: @escaping @MainActor (String) -> Void
    ) {
        guard navigationRebindPrepared else {
            return
        }
        scheduleNavigationRebindResume(
            currentRuntimeState: currentRuntimeState,
            domStore: domStore,
            onRecoverableError: onRecoverableError
        )
    }

    func scheduleNavigationRebindResume(
        currentRuntimeState: @escaping @MainActor () -> SessionActivationPlan.RuntimeAttachmentState,
        domStore: WIDOMStore,
        onRecoverableError: @escaping @MainActor (String) -> Void
    ) {
        guard navigationRebindTask == nil else {
            return
        }
        guard let webView = connectedPageWebView else {
            resetNavigationRebindState()
            return
        }
        let resumeDOMAfterLoad = !webView.isLoading

        navigationRebindTask = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else {
                return
            }
            defer {
                self.navigationRebindTask = nil
            }
            guard self.connectedPageWebView === webView else {
                return
            }

            if !resumeDOMAfterLoad {
                while webView.isLoading {
                    try? await self.rebindClock.sleep(for: .milliseconds(20))
                    guard !Task.isCancelled else {
                        return
                    }
                    guard self.connectedPageWebView === webView else {
                        return
                    }
                    guard self.navigationRebindPrepared else {
                        return
                    }
                }
            }

            let runtimeState = currentRuntimeState()
            guard runtimeState.domEnabled else {
                self.navigationRebindPrepared = false
                return
            }

            do {
                try await domStore.session.resumeAfterNavigationReconnect(
                    to: webView,
                    reloadDocument: true
                )
            } catch is CancellationError {
                return
            } catch {
                onRecoverableError(error.localizedDescription)
                return
            }

            self.navigationRebindPrepared = false
        }
    }
}
