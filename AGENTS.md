# Repository Guidelines

## Project Structure & Module Organization
- `Sources/WebInspectorEngine`: core DOM/Network engines, runtime actors, and script bridge.
- `Sources/WebInspectorModel`: session state/command/effect reducer models.
- `Sources/WebInspectorRuntime`: session runtime, DOM/Network models, and DOM frontend runtime bridge.
- `Sources/WebInspectorUI`: view controllers and UI presentation layer.
- `Sources/WebInspectorKit`: public facade/re-export layer.
- `Sources/WebInspectorBridge`: Swift bridge + Objective-C runtime bridge integration layer.
- `Tests/WebInspectorEngineTests`, `Tests/WebInspectorRuntimeTests`, `Tests/WebInspectorUITests`, `Tests/WebInspectorIntegrationTests`, `Tests/WebInspectorIntegrationLongTests`: Swift tests grouped by module responsibility (`IntegrationLong` is the opt-in long-running suite).
- `Tests/WebInspectorScriptsTests`: regression tests for committed bundled JavaScript access.
- `Tests/WebInspectorTestSupport`: shared Swift test helpers.
- `Sources/WebInspectorScripts/TypeScript/Tests`: Vitest suites for DOM/network helper scripts.
- `Tools/WebInspectorScriptsTypeScriptTests`: pnpm/vitest harness so `node_modules` stays out of `Sources/`.
- `Luminiss/`: app project.
- `Plugins/WebInspectorKitObfuscatePlugin/ObfuscateJS/`: JavaScript bundling toolchain used by `./Scripts/generate-bundled-js.sh`.

## Test Commands
Run from repository root:
- `./Scripts/generate-bundled-js.sh`: sync ObfuscateJS dependencies and regenerate `Generated/WebInspectorScriptsGenerated/CommittedBundledJavaScriptData.swift` after changing TypeScript or ObfuscateJS inputs.
- `xcodebuild test -workspace WebInspectorKit.xcworkspace -scheme WebInspectorUITests -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`: run fast UI-focused Swift tests.
- `xcodebuild test -workspace WebInspectorKit.xcworkspace -scheme WebInspectorIntegrationTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`: run fast integration Swift tests (default gate).
- `xcodebuild test -workspace WebInspectorKit.xcworkspace -scheme WebInspectorIntegrationLongTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`: run long-running integration scenarios when explicitly needed.
- `pnpm --dir Tools/WebInspectorScriptsTypeScriptTests run test`: run TypeScript tests with Vitest.
- `pnpm --dir Tools/WebInspectorScriptsTypeScriptTests run typecheck`: run strict TypeScript type checks.
- `xcrun simctl list devices available`: list valid simulator destinations when destination names differ locally.

## Bundled JavaScript Workflow
- Swift package consumers should never need Node tooling during build.
- If you change `Sources/WebInspectorScripts/TypeScript`, `Plugins/WebInspectorKitObfuscatePlugin/ObfuscateJS/obfuscate.js`, or `Plugins/WebInspectorKitObfuscatePlugin/ObfuscateJS/obfuscate.config.json`, run `./Scripts/generate-bundled-js.sh`.
- `./Scripts/generate-bundled-js.sh` always runs `pnpm install --frozen-lockfile` in `Plugins/WebInspectorKitObfuscatePlugin/ObfuscateJS` before regeneration.
- Commit regenerated `Generated/WebInspectorScriptsGenerated/CommittedBundledJavaScriptData.swift` together with the source change that required it.

## Coding Style & Naming Conventions
- Swift 6.2 / Swift language mode 6 is the baseline.
- Use Xcode default formatting: 4-space indentation, no tabs.
- Follow Swift API Design Guidelines:
  - Types: `UpperCamelCase`
  - Properties/functions: `lowerCamelCase`
- Keep platform-specific files explicit with `+UIKit.swift` (UIKit family) and `+AppKit.swift` (native macOS only). Do not introduce `+Shared.swift`; extract shared logic into module-local support/coordinator types.
- Prefer small, focused types over large view/controller files.

## Testing Guidelines
- Primary package tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
- Name tests by behavior, not implementation details (e.g., `automaticThemeResolvesByColorScheme`).
- Add or update tests for every bug fix and public API behavior change.

## Commit & Pull Request Guidelines
- Follow Conventional Commits observed in history (examples: `fix(dom): ...`, `refactor(network): ...`, `test(...): ...`).
- Keep commits scoped to one concern.
- PRs should include:
  - Purpose and change summary
  - Linked issue/task (if available)
  - Test commands executed and results
  - Screenshots for app UI changes
