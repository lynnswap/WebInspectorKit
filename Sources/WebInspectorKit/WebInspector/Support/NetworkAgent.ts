import {
    clearNetworkRecords,
    configureNetwork,
    installNetworkObserver,
    getBody
} from "./NetworkAgent/NetworkAgentCore";

if (!(window.webInspectorNetworkAgent && window.webInspectorNetworkAgent.__installed)) {
    installNetworkObserver();

    var webInspectorNetworkAgent = {
        configure: configureNetwork,
        clear: clearNetworkRecords,
        getBody: getBody,
        __installed: true
    };

    Object.defineProperty(window, "webInspectorNetworkAgent", {
        value: Object.freeze(webInspectorNetworkAgent),
        writable: false,
        configurable: false
    });
}
