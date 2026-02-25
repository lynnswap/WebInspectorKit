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
    const consumeBootstrapWindowValue = (key: string): unknown => {
        const bag = window as unknown as Record<string, unknown>;
        const value = bag[key];
        try {
            delete bag[key];
        } catch {
        }
        return value;
    };
    const bootstrapToken = (() => {
        const value = consumeBootstrapWindowValue(bootstrapTokenKey);
        return typeof value === "string" ? value : "";
    })();
    const bootstrapPageHookMode = (() => {
        const value = consumeBootstrapWindowValue(bootstrapPageHookModeKey);
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
