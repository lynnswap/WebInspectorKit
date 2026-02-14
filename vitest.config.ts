import { defineConfig } from "vitest/config";

export default defineConfig({
    test: {
        environment: "jsdom",
        include: ["Tests/TypeScript/**/*.test.ts"],
        setupFiles: ["Tests/TypeScript/vitest.setup.ts"],
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
