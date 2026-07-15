# WebKit Version Mapping Notes

Last checked: 2026-07-15.

This note records how iOS WebKit framework versions map back to public WebKit
source refs.

## Local Reference Checkouts

The current audit used the read-only sources under `/Users/kn/Dev/WebKit`:

| Path | Ref | WebInspectorUI | Purpose |
| --- | --- | --- | --- |
| `WebKit-iOS18.5-7621.2.5.10.10` | `WebKit-7621.2.5.10.10` / `4bdf67c5c75` | Absent from the reduced checkout | Known iOS 18.5-era version and platform configuration. Its local Git alternates path is stale, but the checked-out source files remain readable. |
| `WebKit-iOS26.5-7624.2.5.10-branch` | `safari-7624.2.5.10-branch` / `eafd2a9b9776` | Absent from the reduced checkout | Public source branch whose `Version.xcconfig` matches WebKit source version `624.2.5.10.4`. |
| `WebKit_latest` | `main` / `b42421de79d1` | Complete | Current upstream source plus the historical release tags used for frontend behavior comparison. |

The sparse checkout includes:

- `Configurations/Version.xcconfig`
- `Source/WebKit/UIProcess/Inspector/**`
- `Source/WebKit/UIProcess/WebPageProxy.*`
- `Source/WebKit/UIProcess/API/Cocoa/WKWebView*`
- `Source/JavaScriptCore/inspector/InspectorAgentRegistry.*`
- `Source/JavaScriptCore/inspector/InspectorAgentBase.*`
- `Source/JavaScriptCore/inspector/InspectorFrontendRouter.*`
- `Source/JavaScriptCore/inspector/InspectorBackendDispatcher.*`
- `Source/WTF/wtf/Vector.h`
- `Source/WTF/wtf/WeakRef.h`

Because the two version-specific directories do not contain
`Source/WebInspectorUI`, frontend behavior was compared in the complete object
store at these exact refs:

| Product source | Ref | Commit |
| --- | --- | --- |
| Safari 17.6 / iOS 17.6 | `releases/Apple/Safari-17.6-iOS-17.6` | `91977c6e5b061969e921e166d6567b8f84a18f70` |
| Safari 18 / iOS 18.0 | `releases/Apple/Safari-18-iOS-18.0` | `f3bebebccb505852506f40ffe2384268bec2c29d` |
| Current upstream | `main` | `b42421de79d1c2daf9b4c26119113cf9926f6260` |

Across all three refs, `NetworkTabContentView` directly constructs
`NetworkTableContentView`, `NetworkManager.initializeTarget` directly enables
the Network agent, and there is no Network-specific retry presentation or
frontend teardown path. A resource-tree error is logged and returned from the
Network owner; it does not create a retry UI. WebInspectorKit likewise exposes
no Network retry action. It distinguishes only the dispatcher's JSON-RPC
`-32601` `MethodNotFound` response as static feature non-support; other
bootstrap failures fail the attachment. See `Docs/Architecture.md` for the
resulting lifecycle contract.

The version-specific iOS 18.5 and iOS 26.5 sources and current upstream also
agree on page-target replacement ordering in
`WebPageInspectorController::didCommitProvisionalPage`: the new target is
committed, `Target.didCommitProvisionalTarget(old, new)` is dispatched, and
only then are retired targets reported through `Target.targetDestroyed`.
WebInspectorKit therefore retargets the logical page at the commit event and
ignores later destruction of the retired physical target for binding purposes.
Destruction of the still-current target has no equivalent replacement evidence
and remains terminal.

## Mapping Rule

Do not compare the iOS runtime `CFBundleVersion` to WebKit public source refs as
an exact string. WebKit defines the platform prefix in
`Configurations/Version.xcconfig`.

For iPhone SDK builds:

```xcconfig
SYSTEM_VERSION_PREFIX[sdk=iphone*] = 8
BUNDLE_VERSION_Production = $(SYSTEM_VERSION_PREFIX)$(FULL_VERSION)
SHORT_VERSION_STRING_Production = $(SYSTEM_VERSION_PREFIX)$(MAJOR_VERSION)
```

That means an iOS WebKit framework version like `8624.2.5.10.4` maps to WebKit
source version `624.2.5.10.4`. Public WebKit refs use the `WebKit-7...` naming
family, so the practical public-ref search key is usually `WebKit-7624.2.5.10.4`
or a matching `safari-7624.2.5.10*` branch.

The leading digit is therefore meaningful:

| Runtime framework version | Strip iOS prefix | Public WebKit search key |
| --- | --- | --- |
| `8621.3.11.10.3` | `621.3.11.10.3` | `WebKit-7621.3.11.10.3` / `safari-7621.3.11.10*` |
| `8624.2.5.10.4` | `624.2.5.10.4` | `WebKit-7624.2.5.10.4` / `safari-7624.2.5.10*` |
| `8625.1.22.10.2` | `625.1.22.10.2` | `WebKit-7625.1.22.10.2` / `safari-7625.1.22*` |

## Checked Runtimes

| Simulator runtime | WebKit `CFBundleVersion` | `CFBundleShortVersionString` | Public source status |
| --- | --- | --- | --- |
| iOS 18.6 `22G86` | `8621.3.11.10.3` | `8621` | Exact public tag/branch was not found by `git ls-remote`. |
| iOS 26.5 `23F77` | `8624.2.5.10.4` | `8624` | Exact tag was not found; `safari-7624.2.5.10-branch` exists and matches `Version.xcconfig`. |
| iOS 27.0 `24A5380g` | `8625.1.22.10.2` | `8625` | Exact public tag/branch was not found by `git ls-remote`. |

## Commands

Read the WebKit version from a simulator runtime:

```sh
/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleVersion' \
  -c 'Print :CFBundleShortVersionString' \
  -c 'Print :DTPlatformVersion' \
  "$SIMULATOR_ROOT/System/Library/Frameworks/WebKit.framework/Info.plist"
```

Search public WebKit refs:

```sh
git ls-remote --heads https://github.com/WebKit/WebKit.git 'refs/heads/safari-7624.2.5.10*'
git ls-remote --tags https://github.com/WebKit/WebKit.git 'refs/tags/WebKit-7624.2.5.10*'
```
