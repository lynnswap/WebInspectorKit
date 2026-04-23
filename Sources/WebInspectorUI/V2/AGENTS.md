# V2 Guidelines

- For new V2-specific classes, structs, enums, protocols, and typealiases added under `Sources/WebInspectorUI/V2`, prefix the type name with `V2_`.
- This rule applies to newly defined V2 types. If an existing V1 type is reused as-is, the prefix is not required.
- In the final migration phase, after `V1` is removed and V2 becomes the canonical implementation, remove the `V2_` prefix from the remaining V2 types.
- During the transition period, prioritize avoiding name collisions between V1 and V2 types.
