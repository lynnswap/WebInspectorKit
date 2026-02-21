import { defineConfig } from "vitest/config";

export default defineConfig({
    test: {
        environment: "jsdom",
        include: ["WebInspectorKit/Tests/TypeScript/**/*.test.ts"],
        setupFiles: ["WebInspectorKit/Tests/TypeScript/vitest.setup.ts"],
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
