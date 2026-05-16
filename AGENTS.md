# Repository Guidelines

## Testing

- Package tests can be run from Xcode through the shared `WebInspectorKit` scheme.
- Default validation command:

```sh
xcodebuild test \
  -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorKit \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```
