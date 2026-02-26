# Repository Guidelines

## Project Structure & Module Organization
- `Sources/WebInspectorEngine`: core DOM/Network engines, runtime actors, and script bridge.
- `Sources/WebInspectorModel`: session state/command/effect reducer models.
- `Sources/WebInspectorRuntime`: session runtime, DOM/Network models, and DOM frontend runtime bridge.
- `Sources/WebInspectorUI`: view controllers and UI presentation layer.
- `Sources/WebInspectorKit`: public facade/re-export layer.
- `Sources/WebInspectorBridge`: Swift bridge + Objective-C runtime bridge integration layer.
- `Tests/WebInspectorKitTests/WebInspectorEngineTests` and `Tests/WebInspectorKitTests/WebInspectorKitFeatureTests`: Swift tests.
- `Tests/TypeScript`: Vitest suites for DOM/network helper scripts.
- `MiniBrowser/`: sample host app with app and UI tests.
- `Plugins/WebInspectorKitObfuscatePlugin/ObfuscateJS/`: JavaScript obfuscation toolchain used by the build plugin.

## Test Commands
Run from repository root:
- `xcodebuild -workspace WebInspectorKit.xcworkspace -scheme WebInspectorKitTests -destination 'platform=macOS' test`: run package tests on macOS.
- `xcodebuild -workspace WebInspectorKit.xcworkspace -scheme WebInspectorKitTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' test`: run iOS Simulator tests.
- `pnpm --dir Tests/TypeScript run test`: run TypeScript tests with Vitest.
- `pnpm --dir Tests/TypeScript run typecheck`: run strict TypeScript type checks.
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
