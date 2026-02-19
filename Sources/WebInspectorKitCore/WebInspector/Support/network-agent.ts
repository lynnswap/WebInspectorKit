import {
    clearNetworkRecords,
    configureNetwork,
    installNetworkObserver,
    getBody,
    getBodyForHandle
} from "./NetworkAgent/network-agent-core";

if (!(window.webInspectorNetworkAgent && window.webInspectorNetworkAgent.__installed)) {
    installNetworkObserver();

    var webInspectorNetworkAgent = {
        configure: configureNetwork,
        clear: clearNetworkRecords,
        getBody: getBody,
        getBodyForHandle: getBodyForHandle,
        __installed: true
    };

    Object.defineProperty(window, "webInspectorNetworkAgent", {
        value: Object.freeze(webInspectorNetworkAgent),
        writable: false,
        configurable: false
    });
}
