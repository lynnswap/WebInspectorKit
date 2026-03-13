import { defineConfig } from "vitest/config";

function fileURLPath(url: URL): string {
    const pathname = decodeURIComponent(url.pathname);
    if (/^\/[A-Za-z]:/.test(pathname)) {
        return pathname.slice(1);
    }
    return pathname;
}

const typeScriptRoot = fileURLPath(
    new URL("../../Sources/WebInspectorResources/TypeScript", import.meta.url)
);

export default defineConfig({
    resolve: {
        alias: {
            "@wi-ts": typeScriptRoot
        }
    },
    test: {
        environment: "jsdom",
        include: ["./**/*.test.ts"],
        setupFiles: ["./vitest.setup.ts"],
        clearMocks: true,
        restoreMocks: true,
        unstubGlobals: true,
        fileParallelism: false,
        environmentOptions: {
            jsdom: {
                pretendToBeVisual: true
            }
        }
    }
});
