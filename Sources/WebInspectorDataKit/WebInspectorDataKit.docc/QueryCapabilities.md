# Query Capabilities

Create Network and Console result sets with concrete, closed query values.

## Query Network Requests

Use ``NetworkModelController/fetchedResults(for:isolation:)`` with a
``NetworkRequestQuery``. A query atomically defines membership, ordering,
sectioning, and its visible window:

```swift
let query = NetworkRequestQuery(
    filter: .all([
        .resourceCategory(.xhrFetch),
        .searchableText(containing: "graphql"),
    ]),
    sortBy: [.requestSentTimestamp(order: .reverse)],
    sectionBy: .method,
    fetchLimit: 100
)
let requests = context.network.fetchedResults(for: query)
```

Network filters support method and URL equality or containment, searchable-text
equality or containment, MIME equality, one or many resource categories, status
code comparisons, and `all`/`any` composition. Network sorting supports the
request-sent timestamp in either direction. Sections support method, resource
type, resource category, and MIME type.

DataKit applies a query in this order: filter membership, ordered sort criteria
and their tie rule, offset, limit, then sectioning of the visible window. Section
order follows each section's first visible item. Limits apply to the whole
result, not separately to each section. With no sort criteria, Network requests
and Console messages remain in insertion order.

A status-code filter substitutes its `whenMissing` value before comparison when
WebKit has not reported a status. The default substitution is zero.

## Query Console Messages

Use ``ConsoleModelController/fetchedResults(for:isolation:)`` with a
``ConsoleMessageQuery``:

```swift
let query = ConsoleMessageQuery(
    filter: .level(.init(rawValue: "warning")),
    sortBy: [.text(comparison: .lexical, order: .reverse)],
    sectionBy: .source,
    fetchLimit: 100
)
let messages = context.console.fetchedResults(for: query)
```

Console filters support source, level, kind, URL, text containment, and
`all`/`any` composition. Console sorting supports text with localized-standard
or lexical comparison and severity-level raw values, in either direction.
Sections support source, level, kind, and URL.

Network timestamps without a reported value sort before reported timestamps in
forward order and after them in reverse order. Equal Network timestamps follow
insertion direction. Console text uses the selected comparison; severity raw
values use localized-standard comparison. Equal Console sort values retain
message insertion order in either direction.

Filters are closed, nonthrowing values. DataKit does not evaluate arbitrary
Foundation predicate or sort expressions, and a query cannot fail later because
an expression was unsupported. `all` and `any` compose membership declaratively;
`all([])` matches and `any([])` does not.

`fetchLimit` and `fetchOffset` use unsigned counts. Values larger than the
current collection safely describe the remaining prefix or an empty result.

## Update a Live Query

Call `updateQuery(_:)` on a ``WebInspectorFetchedResults`` or
``WebInspectorFetchedResultsController`` to replace the filter, sort, section,
limit, and offset in one reset transaction:

```swift
try requests.updateQuery(
    NetworkRequestQuery(
        filter: .statusCode(atLeast: 400),
        sortBy: [.requestSentTimestamp(order: .reverse)]
    )
)
```

## Migrate Generic Fetch Construction

The previous generic construction surface accepted values DataKit could not
execute. Migrate each operation as one semantic query:

| Previous construction | Concrete query |
| --- | --- |
| `WebInspectorFetchDescriptor<NetworkRequest>` | `NetworkRequestQuery` |
| `WebInspectorFetchDescriptor<ConsoleMessage>` | `ConsoleMessageQuery` |
| Foundation `Predicate` | A model-specific `Filter` factory |
| Foundation `SortDescriptor` | A model-specific `Sort` factory |
| `sectionBy: \.method` | `NetworkRequestQuery(sectionBy: .method)` |
| `sectionBy: \.level` | `ConsoleMessageQuery(sectionBy: .level)` |
| `context.fetchedResults(...)` | `context.network.fetchedResults(...)` or `context.console.fetchedResults(...)` |
| `updateFetchDescriptor` | `updateQuery` |
| `WebInspectorFetchRequest` | Mutate and submit a query value |

Replace a mutable fetch request by copying and resubmitting the current query:

```swift
var query = requests.query
query.fetchLimit = 200
query.fetchOffset = 100
try requests.updateQuery(query)
```

Only ``NetworkRequest`` and ``ConsoleMessage`` are registered query models.
Consumer-defined ``WebInspectorPersistentModel`` types can still participate in
generic snapshots and transactions, but cannot be fetched from a context.
