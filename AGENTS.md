# Repository Guidelines

## Project Structure & Module Organization
- `WebInspectorKit/Sources/WebInspectorKitCore`: core DOM/Network engines, runtime actors, and script bridge.
- `WebInspectorKit/Sources/WebInspectorKit`: public UI/container layer and pane controllers.
- `WebInspectorKit/Sources/WebInspectorKitSPIObjC`: Objective-C runtime bridge used by Swift targets.
- `WebInspectorKit/Tests/WebInspectorKitCoreTests` and `WebInspectorKit/Tests/WebInspectorKitFeatureTests`: tests.
- `WebInspectorKit/Tests/TypeScript`: Vitest suites for DOM/network helper scripts.
- `MiniBrowser/`: sample host app with app and UI tests.
- `ObfuscateJS/`: JavaScript obfuscation toolchain used by the build plugin.

## Test Commands
Run from repository root:
- `xcodebuild -workspace WebInspectorKit.xcworkspace -scheme WebInspectorKitTests -destination 'platform=macOS' test`: run package tests on macOS.
- `xcodebuild -workspace WebInspectorKit.xcworkspace -scheme WebInspectorKitTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' test`: run iOS Simulator tests.
- `pnpm -s run test:ts`: run TypeScript tests with Vitest.
- `pnpm -s run typecheck:ts`: run strict TypeScript type checks.
- `xcrun simctl list devices available`: list valid simulator destinations when destination names differ locally.

## Coding Style & Naming Conventions
- Swift 6.2 / Swift language mode 6 is the baseline.
- Use Xcode default formatting: 4-space indentation, no tabs.
- Follow Swift API Design Guidelines:
  - Types: `UpperCamelCase`
  - Properties/functions: `lowerCamelCase`
- Keep platform-specific files explicit using suffixes like `+iOS.swift` and `+macOS.swift`.
- Prefer small, focused types over large view/controller files.

## Testing Guidelines
- Primary package tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
- MiniBrowser UI tests use `XCTest` and should remain deterministic (e.g., fixed accessibility identifiers).
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
