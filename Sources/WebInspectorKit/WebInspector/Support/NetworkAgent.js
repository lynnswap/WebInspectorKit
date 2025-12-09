import {
    clearNetworkRecords,
    installNetworkObserver,
    setNetworkLoggingMode,
    getResponseBody,
    getRequestBody
} from "./NetworkAgent/NetworkAgentCore.js";

if (!(window.webInspectorNetwork && window.webInspectorNetwork.__installed)) {
    installNetworkObserver();

    var webInspectorNetwork = {
        setLoggingMode: setNetworkLoggingMode,
        clearRecords: clearNetworkRecords,
        getResponseBody: getResponseBody,
        getRequestBody: getRequestBody,
        __installed: true
    };

    Object.defineProperty(window, "webInspectorNetwork", {
        value: Object.freeze(webInspectorNetwork),
        writable: false,
        configurable: false
    });
}
