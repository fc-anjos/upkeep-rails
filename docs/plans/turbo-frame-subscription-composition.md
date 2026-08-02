# Turbo Frame subscription composition

## Goal

Keep one authoritative Upkeep subscription for the visible page across Turbo
Frame navigation.

A frame response is not a page response. Turbo extracts only the matching
`<turbo-frame>`, and frame endpoints may omit the application shell and sibling
frames. Replacing the page subscription with the response capture would
therefore lose dependencies that are still visible. Keeping both captures would
retain stale dependencies and duplicate invalidation fan-out.

## Model

`turbo_frame_tag` establishes a generic render scope in the dependency graph:

```text
page
├── shell
├── turbo_frame:filters
│   └── current frame dependencies
└── turbo_frame:details
    └── current frame dependencies
```

For a Turbo Frame GET, the browser sends the current subscription identity and
Turbo's target frame id. Upkeep captures the response, finds the matching render
scope in both graphs, and creates a new pending subscription from:

```text
old page graph - old target subtree + response target subtree
```

The old subscription remains active while Action Cable connects the candidate.
After `connected`, the client installs the candidate as current and
unsubscribes the old subscription. Rejected or superseded candidates never
replace the active page graph.

## Invariants

- There is one current page subscription per browser document.
- A page with no reactive full render keeps a dormant coordinator; its first
  reactive frame establishes the subscription.
- A frame transition changes only the matching render scope.
- Shell and sibling dependencies survive frame navigation.
- Replaced dependencies leave the reverse index when the old cable subscription
  disconnects.
- The server accepts a base subscription only with a valid activation token and
  the same derived subscriber identity.
- A response cannot become current unless its Action Cable subscription
  connects.
- Concurrent frame responses are ordered by the browser transition generation;
  a late response cannot restore an older graph.
- Expired or structurally incompatible base graphs request a full Turbo render
  instead of discarding already-active scopes.

## Protocol

Before a frame fetch, the client adds these headers when a current subscription
exists:

- `X-Upkeep-Subscription-Id`
- `X-Upkeep-Subscription-Token`

After composing and registering the replacement, the response adds:

- `X-Upkeep-Subscription-Id`
- `X-Upkeep-Subscription-Token`
- `X-Upkeep-Subscription-Channel`
- `X-Upkeep-Subscription-Stream`

`turbo:frame-render` is the commit point. The custom subscription source reads
the response headers and starts the atomic cable transition. Full-page Turbo
Drive visits continue to replace the body-scoped source element normally.

## Implementation

- [x] Capture `turbo_frame_tag` blocks as `turbo_frame` graph nodes with
  controller replay recipes.
- [x] Add generic DAG subtree replacement and recorder composition.
- [x] Validate and compose frame registrations against the active page
  subscription.
- [x] Return candidate subscription metadata in response headers.
- [x] Keep the body source stable during frame visits and atomically switch its
  Action Cable subscription.
- [x] Cover graph composition, replay/targeting, request protocol, race/rejection
  behavior, and a real Turbo Frame navigation followed by live invalidation.
- [x] Regenerate Pulse's installed client, run the full Upkeep proof suite, and
  repeat the Pulse browser scenario without a page reload.
