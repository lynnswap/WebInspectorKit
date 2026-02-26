import { defineConfig } from "vitest/config";

export default defineConfig({
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
