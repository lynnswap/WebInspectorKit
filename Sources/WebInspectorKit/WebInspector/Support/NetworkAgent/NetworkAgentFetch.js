const installFetchPatch = () => {
    if (typeof window.fetch !== "function") {
        return;
    }
    const nativeFetch = window.fetch;
    if (nativeFetch.__wiNetworkPatched) {
        return;
    }
    const patched = async function() {
        const shouldTrack = true;
        const args = Array.from(arguments);
        const [input, init = {}] = args;
        const method = init.method || (input && input.method) || "GET";
        const identity = shouldTrack ? nextRequestIdentity() : null;
        const url = typeof input === "string" ? input : (input && input.url) || "";
        if (shouldIgnoreUrl(url)) {
            return nativeFetch.apply(window, args);
        }
        const headers = normalizeHeaders(init.headers || (input && input.headers));
        const requestBodyInfo = serializeRequestBody(init.body);

        if (shouldTrack && identity) {
            recordStart(
                identity,
                url,
                String(method).toUpperCase(),
                headers,
                "fetch",
                undefined,
                undefined,
                requestBodyInfo
            );
        }

        try {
            const response = await nativeFetch.apply(window, args);
            let mimeType;
            let responseBodyInfo = null;
            if (shouldTrack && identity) {
                mimeType = recordResponse(identity, response, "fetch");
                postNetworkEvent({
                    type: "responseExtra",
                    session: identity.session,
                    requestId: identity.requestId,
                    responseHeaders: normalizeHeaders(response.headers),
                    blockedCookies: [],
                    wallTime: wallTime()
                });
                try {
                    responseBodyInfo = await captureResponseBody(response, mimeType);
                } catch {
                    responseBodyInfo = null;
                }
                const encodedLength = estimatedEncodedLength(
                    captureContentLength(response),
                    responseBodyInfo
                );
                recordFinish(
                    identity,
                    encodedLength,
                    "fetch",
                    response && typeof response.status === "number" ? response.status : undefined,
                    response && typeof response.statusText === "string" ? response.statusText : undefined,
                    mimeType,
                    undefined,
                    undefined,
                    responseBodyInfo
                );
            }
            return response;
        } catch (error) {
            if (shouldTrack && identity) {
                recordFailure(identity, error, "fetch");
            }
            throw error;
        }
    };
    patched.__wiNetworkPatched = true;
    window.fetch = patched;
};
