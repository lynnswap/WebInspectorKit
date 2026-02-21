import {
    bootstrapNetworkAuthToken,
    clearNetworkRecords,
    configureNetwork,
    installNetworkObserver,
    getBody,
    getBodyForHandle
} from "./NetworkAgent/network-agent-core";

if (!(window.webInspectorNetworkAgent && window.webInspectorNetworkAgent.__installed)) {
    const bootstrapTokenKey = "__wiNetworkControlToken";
    const bootstrapPageHookModeKey = "__wiNetworkPageHookMode";
    const bootstrapToken = (() => {
        const bag = window as Window & Record<string, unknown>;
        const value = bag[bootstrapTokenKey];
        try {
            delete bag[bootstrapTokenKey];
        } catch {
        }
        return typeof value === "string" ? value : "";
    })();
    const bootstrapPageHookMode = (() => {
        const bag = window as Window & Record<string, unknown>;
        const value = bag[bootstrapPageHookModeKey];
        try {
            delete bag[bootstrapPageHookModeKey];
        } catch {
        }
        return value === "disabled" ? "disabled" : "enabled";
    })();

    if (bootstrapToken) {
        bootstrapNetworkAuthToken(bootstrapToken);
    }

    installNetworkObserver({
        pageHookMode: bootstrapPageHookMode
    });

    var webInspectorNetworkAgent = {
        configure: configureNetwork,
        clear: clearNetworkRecords,
        getBody: getBody,
        getBodyForHandle: getBodyForHandle,
        bootstrapAuthToken: bootstrapNetworkAuthToken,
        __installed: true
    };

    Object.defineProperty(window, "__wiBootstrapNetworkAuthToken", {
        value: bootstrapNetworkAuthToken,
        writable: false,
        configurable: true,
        enumerable: false
    });

    Object.defineProperty(window, "webInspectorNetworkAgent", {
        value: Object.freeze(webInspectorNetworkAgent),
        writable: false,
        configurable: false
    });
}
