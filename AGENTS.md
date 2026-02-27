# Repository Guidelines

## Project Structure & Module Organization
- `Sources/WebInspectorEngine`: core DOM/Network engines, runtime actors, and script bridge.
- `Sources/WebInspectorModel`: session state/command/effect reducer models.
- `Sources/WebInspectorRuntime`: session runtime, DOM/Network models, and DOM frontend runtime bridge.
- `Sources/WebInspectorUI`: view controllers and UI presentation layer.
- `Sources/WebInspectorKit`: public facade/re-export layer.
- `Sources/WebInspectorBridge`: Swift bridge + Objective-C runtime bridge integration layer.
- `Tests/WebInspectorEngineTests`, `Tests/WebInspectorRuntimeTests`, `Tests/WebInspectorUITests`, `Tests/WebInspectorIntegrationTests`, `Tests/WebInspectorIntegrationLongTests`: Swift tests grouped by module responsibility (`IntegrationLong` is the opt-in long-running suite).
- `Tests/WebInspectorTestSupport`: shared Swift test helpers.
- `Sources/WebInspectorScripts/TypeScript/Tests`: Vitest suites for DOM/network helper scripts.
- `MiniBrowser/`: sample host app with app and UI tests.
- `Plugins/WebInspectorKitObfuscatePlugin/ObfuscateJS/`: JavaScript obfuscation toolchain used by the build plugin.

## Test Commands
Run from repository root:
- `xcodebuild test -workspace WebInspectorKit.xcworkspace -scheme WebInspectorUITests -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`: run fast UI-focused Swift tests.
- `xcodebuild test -workspace WebInspectorKit.xcworkspace -scheme WebInspectorIntegrationTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`: run fast integration Swift tests (default gate).
- `xcodebuild test -workspace WebInspectorKit.xcworkspace -scheme WebInspectorIntegrationLongTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`: run long-running integration scenarios when explicitly needed.
- `pnpm --dir Sources/WebInspectorScripts/TypeScript/Tests run test`: run TypeScript tests with Vitest.
- `pnpm --dir Sources/WebInspectorScripts/TypeScript/Tests run typecheck`: run strict TypeScript type checks.
- `xcodebuild -workspace WebInspectorKit.xcworkspace -scheme MiniBrowser -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' test`: run MiniBrowser UI tests when UI-related files changed.
- `xcrun simctl list devices available`: list valid simulator destinations when destination names differ locally.

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
- MiniBrowser UI tests use `XCTest` and should remain deterministic (e.g., fixed accessibility identifiers).
- Run MiniBrowser UI tests only when changes affect `MiniBrowser/**`, `Sources/WebInspectorUI/**`, `Sources/WebInspectorRuntime/**` UI paths, or `Sources/WebInspectorKit/**` container-facing API.
- Name tests by behavior, not implementation details (e.g., `automaticThemeResolvesByColorScheme`).
- Add or update tests for every bug fix and public API behavior change.

## Commit & Pull Request Guidelines
- Follow Conventional Commits observed in history (examples: `fix(dom): ...`, `refactor(network): ...`, `test(...): ...`).
- Keep commits scoped to one concern.
- PRs should include:
  - Purpose and change summary
  - Linked issue/task (if available)
  - Test commands executed and results
  - Screenshots for MiniApp UI changes
