# Repository Guidelines

## Releases

- Follow [RELEASING.md](RELEASING.md). `Scripts/release.py start` creates the approved
  tag and draft, then starts the workflow that validates and publishes it.

## Testing

- Package tests can be run from Xcode through the shared `WebInspectorKit` scheme.
- Default validation command:

```sh
xcodebuild test \
  -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorKit \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```
