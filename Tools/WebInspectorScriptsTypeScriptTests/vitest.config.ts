import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const setupFilePath = fileURLToPath(new URL("./vitest.setup.ts", import.meta.url));

export default defineConfig({
    test: {
        environment: "jsdom",
        include: ["./**/*.test.ts"],
        setupFiles: [setupFilePath],
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
