# Repository Guidelines

## Project Structure & Module Organization
- `Sources/WebInspectorCore`: core DOM / Network / Session / Shared models, stores, and runtime coordination.
- `Sources/WebInspectorResources`: script APIs, bundled resources, localization, assets, and TypeScript sources.
- `Sources/WebInspectorTransport`: backend, bridge, state, and transport wiring between WebKit/runtime and the inspector.
- `Sources/WebInspectorUI`: container, DOM, Network, platform bridge, and shared presentation layer types.
- `Sources/WebInspectorKit`: public facade / re-export layer for the package product.
- `Sources/WebInspectorBridge/ObjCShim`, `Sources/WebInspectorTransportObjCShim`: Objective-C shims that support SPI and native transport bridging.
- `Tests/WebInspectorCoreTests`, `Tests/WebInspectorDOMTests`, `Tests/WebInspectorNetworkTests`, `Tests/WebInspectorTransportTests`, `Tests/WebInspectorUITests`, `Tests/WebInspectorIntegrationTests`, `Tests/WebInspectorIntegrationLongTests`, `Tests/WebInspectorShellTests`: Swift tests grouped by responsibility (`IntegrationLong` remains the opt-in long-running suite).
- `Tests/WebInspectorTestSupport`: shared Swift test helpers.
- `Tests/TypeScript`: Vitest suites for DOM/network helper scripts.
- `MiniBrowser/`: sample host app.
- `Plugins/WebInspectorKitObfuscatePlugin/ObfuscateJS/`: JavaScript obfuscation toolchain used by the build plugin.

## Test Commands
Run from repository root:
- `swift test`: run the default Swift Package test suite across the package targets.
- `pnpm --dir Tests/TypeScript run test`: run TypeScript tests with Vitest.
- `pnpm --dir Tests/TypeScript run typecheck`: run strict TypeScript type checks.
- `xcodebuild -workspace WebInspectorKit.xcworkspace -scheme MiniBrowser -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' test`: run the sample app/UI runtime integration gate when MiniBrowser or runtime wiring changes.
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
- Name tests by behavior, not implementation details (e.g., `automaticThemeResolvesByColorScheme`).
- Add or update tests for every bug fix and public API behavior change.

## Commit & Pull Request Guidelines
- Follow Conventional Commits observed in history (examples: `fix(dom): ...`, `refactor(network): ...`, `test(...): ...`).
- Keep commits scoped to one concern.
- PRs should include:
  - Purpose and change summary
  - Linked issue/task (if available)
  - Test commands executed and results
  - Screenshots for MiniBrowser UI changes
