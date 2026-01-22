#if os(iOS)
import Foundation
import OSLog
import WebKit

private let logger = Logger(
    subsystem: "MiniBrowser",
    category: "InjectedBundleProcessPool"
)

enum InjectedBundleProcessPool {
    private static let bundleName = "MiniBrowserInjectedBundle"
    private static var cachedProcessPool: WKProcessPool?
    private static let debugEnabled = true

    static func configure(_ configuration: WKWebViewConfiguration) {
        if let cachedProcessPool {
            configuration.processPool = cachedProcessPool
            return
        }
        debugLog("configure begin")
        guard let bundleURL = Bundle.main.url(forResource: bundleName, withExtension: "bundle") else {
            logger.error("Injected bundle not found: \(bundleName, privacy: .public)")
            NSLog("InjectedBundleProcessPool: injected bundle not found: \(bundleName)")
            return
        }
        let resolvedBundleURL = bundleURL.resolvingSymlinksInPath()
        let originalBundlePath = bundleURL.path
        let bundlePath = resolvedBundleURL.path
        debugLog("bundleURL=\(originalBundlePath)")
        if resolvedBundleURL != bundleURL {
            debugLog("bundleURL(resolved)=\(bundlePath)")
        }
        let exists = FileManager.default.fileExists(atPath: bundlePath)
        debugLog("bundle exists=\(exists)")
        if let bundle = Bundle(url: bundleURL) {
            debugLog("bundleIdentifier=\(bundle.bundleIdentifier ?? "nil")")
            debugLog("executableURL=\(bundle.executableURL?.path ?? "nil")")
        } else {
            NSLog("InjectedBundleProcessPool: failed to load bundle at \(bundlePath)")
        }
        let appBundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        debugLog("appBundleURL=\(appBundleURL.path)")
        guard let processPool = makeProcessPool(bundleURL: resolvedBundleURL, appBundleURL: appBundleURL) else {
            logger.error("Failed to create process pool with injected bundle.")
            NSLog("InjectedBundleProcessPool: failed to create process pool with injected bundle.")
            return
        }
        cachedProcessPool = processPool
        configuration.processPool = processPool
        debugLog("configure done")
    }

    private static func makeProcessPool(bundleURL: URL, appBundleURL: URL) -> WKProcessPool? {
        guard let configurationClass = NSClassFromString("_WKProcessPoolConfiguration") as? NSObject.Type else {
            logger.error("Missing _WKProcessPoolConfiguration.")
            NSLog("InjectedBundleProcessPool: missing _WKProcessPoolConfiguration.")
            return nil
        }
        let poolConfiguration = configurationClass.init()
        poolConfiguration.setValue(bundleURL, forKey: "injectedBundleURL")
        var readAccessURLs = [bundleURL]
        if appBundleURL != bundleURL {
            readAccessURLs.append(appBundleURL)
        }
        setConfigurationIfSupported(
            poolConfiguration,
            selectorName: "setAdditionalReadAccessAllowedURLs:",
            key: "additionalReadAccessAllowedURLs",
            value: readAccessURLs
        )
        setConfigurationIfSupported(
            poolConfiguration,
            selectorName: "setUsesWebProcessCache:",
            key: "usesWebProcessCache",
            value: false
        )

        guard let processPoolClass = NSClassFromString("WKProcessPool") as? NSObject.Type else {
            logger.error("Missing WKProcessPool class.")
            NSLog("InjectedBundleProcessPool: missing WKProcessPool class.")
            return nil
        }
        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString("_initWithConfiguration:")
        guard let poolAlloc = processPoolClass.perform(allocSelector)?.takeRetainedValue() as? NSObject else {
            logger.error("Failed to allocate WKProcessPool.")
            NSLog("InjectedBundleProcessPool: failed to allocate WKProcessPool.")
            return nil
        }
        guard poolAlloc.responds(to: initSelector) else {
            logger.error("WKProcessPool does not respond to _initWithConfiguration:.")
            NSLog("InjectedBundleProcessPool: WKProcessPool does not respond to _initWithConfiguration:.")
            return nil
        }
        guard let pool = poolAlloc.perform(initSelector, with: poolConfiguration)?.takeRetainedValue() as? WKProcessPool else {
            logger.error("Failed to initialize WKProcessPool.")
            NSLog("InjectedBundleProcessPool: failed to initialize WKProcessPool.")
            return nil
        }
        logProcessPoolConfiguration(pool)
        return pool
    }

    private static func debugLog(_ message: String) {
        guard debugEnabled else {
            return
        }
        NSLog("InjectedBundleProcessPool: %@", message)
    }

    private static func setConfigurationIfSupported(
        _ configuration: NSObject,
        selectorName: String,
        key: String,
        value: Any
    ) {
        let selector = NSSelectorFromString(selectorName)
        guard configuration.responds(to: selector) else {
            debugLog("configuration missing \(selectorName)")
            return
        }
        configuration.setValue(value, forKey: key)
    }

    private static func logProcessPoolConfiguration(_ pool: WKProcessPool) {
        let selector = NSSelectorFromString("_configuration")
        guard pool.responds(to: selector) else {
            debugLog("WKProcessPool missing _configuration")
            return
        }
        guard let config = pool.perform(selector)?.takeUnretainedValue() as? NSObject else {
            debugLog("WKProcessPool _configuration returned nil")
            return
        }
        if let injectedURL = config.value(forKey: "injectedBundleURL") as? URL {
            debugLog("processPool._configuration.injectedBundleURL=\(injectedURL.path)")
        } else {
            debugLog("processPool._configuration.injectedBundleURL=nil")
        }
        if let additionalURLs = config.value(forKey: "additionalReadAccessAllowedURLs") as? [URL] {
            debugLog("processPool._configuration.additionalReadAccessAllowedURLs.count=\(additionalURLs.count)")
        }
    }
}
#else
import Foundation
import WebKit

enum InjectedBundleProcessPool {
    static func configure(_ configuration: WKWebViewConfiguration) {
    }
}
#endif
