import {
    clearNetworkRecords,
    installNetworkObserver,
    setNetworkLoggingEnabled
} from "./InspectorAgent/InspectorAgentNetwork.js";

if (!(window.webInspectorNetwork && window.webInspectorNetwork.__installed)) {
    installNetworkObserver();

    var webInspectorNetwork = {
        setLoggingEnabled: setNetworkLoggingEnabled,
        clearRecords: clearNetworkRecords,
        __installed: true
    };

    Object.defineProperty(window, "webInspectorNetwork", {
        value: Object.freeze(webInspectorNetwork),
        writable: false,
        configurable: false
    });
}
