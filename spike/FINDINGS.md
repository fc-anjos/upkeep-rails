# Spike: query→node provenance through ReActionView/Herb

Hypothesis tested: with ReActionView as the render path, upkeep can derive
region-level dependencies, personal-island localization, and structural
addressing purely from compiler infrastructure — no idiom catalogs, no view
authoring.

**Verdict: the hypothesis holds, on the public API, with byte-identical
output on the element-bracketing path and ~1.9µs/node capture cost.**
Template identity (source → digest) is available to visitors through public
Herb API (`node.source` with `prism_nodes` enabled — see §2); the earlier
"visitors get no template context" hook-gap claim is RETRACTED in its
strong form. Only the cosmetic filename label needs app-side plumbing.

Test results (verbatim, `ruby spike/provenance_spike_test.rb`):

    6 runs, 81 assertions, 0 failures, 0 errors, 0 skips

Spike size: `lib/prov_spike.rb` ~330 LOC + 6 small templates + 1 test file.

## 1. Extension-point inventory (the primary deliverable)

Versions read: reactionview 0.3.0, herb 0.10.3 (arm64-darwin), Rails 8.1.3.1.

| Extension point | Where | What it gives |
|---|---|---|
| `ReActionView.config.transform_visitors` | `reactionview/config.rb:7,13`; applied in `reactionview/template/handlers/herb.rb:26` (`visitors: visitors + ReActionView.config.transform_visitors`) | **Public compile-time AST hook.** Every template compiled through ReActionView runs `ast.accept(visitor)` for each registered visitor *before* code generation (`herb/engine.rb:158-160`). Mutation is the intended use — `Herb::Engine::DebugVisitor` rewrites the AST this way (wraps ERB output nodes in `<span>`s, injects attributes: `herb/engine/debug_visitor.rb:125-151,174-206,212-269`). |
| `Herb::Engine` `visitors:` property | `herb/engine.rb:92` | Same hook one level lower, usable without ReActionView (our micro-bench uses it directly). |
| `ReActionView::Template::Handlers::Herb#call` | `reactionview/template/handlers/herb.rb:11-30` | The per-template compile entry: receives `(template, source)` — the only place that knows both the template identity and the source. Our shim prepends here. |
| `class_attribute :erb_implementation` | `reactionview/template/handlers/herb.rb:9` | Swap the engine subclass entirely (deeper surgery than we needed). |
| `ReActionView.config.intercept_erb` | `config.rb:5`, `railtie.rb:32-36`, `handlers/erb.rb:10-14` | Routes every `.html.erb` template through the Herb engine — the "run all Rails views through Herb" switch (HTML format only; other formats fall back to stock ERB). |
| Herb AST nodes | `herb/ast/nodes.rb` | Typed nodes with `location` (line/column), mutable child arrays (`children`/`body`/`statements`), `to_hash`/JSON. Everything needed to compute stable node paths and inject synthetic nodes (`ERBContentNode.new` at `nodes.rb:1706`, `Herb::Token`, `Herb::Location.from`). |
| `Herb::Engine::Compiler` | `herb/engine/compiler.rb` | The AST→Ruby code generator. Its token stream (`[type, value, context]`, e.g. compiler.rb:21,448,456-466) **drops node identity** — you cannot hook "which node is emitting" here without a subclass. This is why AST-level injection is the right seam. |

## 2. Template context for visitors — claim RE-VERIFIED (and retracted)

The first version of this document claimed config-registered visitors get no
per-template context and framed an upstream PR. **Re-verification against
the full public API of both gems (herb 0.10.3 and reactionview 0.3.0 — both
the installed AND latest released versions, confirmed via `gem search -r -a`)
shows the strong claim was WRONG:**

- **Template source IS public API on every AST node.** `Herb::ParseResult#initialize`
  assigns the full template source onto the tree (`parse_result.rb:17-22`,
  propagated by `AST::Node#source=`, `node.rb:26-28`) when the parser runs
  with `prism_nodes: true`. That option reaches the engine through the
  public `parser_options` property (`engine.rb:84,134`) and can be enabled
  project-wide with zero code: a `.herb.yml` containing
  `engine: parser_options: prism_nodes: true` plus `Herb.configure(path)`
  (`herb.rb:100-106`, `configuration.rb` engine_option). The spike now runs
  this way: the visitor derives address digests from `node.source`, and
  `test_visitor_self_serves_digest_from_node_source_without_any_shim`
  proves the fully shim-free path (direct `Herb::Engine` compile, no
  ReActionView, no thread-local — digest correct).
- **What genuinely remains unavailable to visitors: the template FILENAME.**
  The engine holds it (`@filename`, from the handler's
  `filename: template.identifier`) but does not pass it to visitors, and
  nodes carry source + line/col only. Checked: visitor construction/accept
  path (`engine.rb:92-101,158-160`), all `Herb::AST::Node` attributes,
  `ParseResult`/`ParserOptions`, `Herb::Template` (none exists; `Herb::Project`
  is CLI-only). For upkeep this is cosmetic — addresses are digest-based;
  the filename only labels human-readable reports — so the spike's
  `HandlerShim` survives solely as (a) the opt-in gate for which view paths
  are instrumented (app policy, not a Herb capability) and (b) the filename
  label. No upstream change is required for the mechanism to work.

**Decision (recorded): the enter/leave lifecycle instrumentation ships in
upkeep**, implemented via the public visitor hook — it is upkeep's own
runtime concern, not an upstream proposal. Other observations, none
blocking: render-time current-node context isn't needed (compile-time
injection provides it); node paths are computed by the visitor (a possible
Herb nicety, not a gap); handler class-level `call` registration works
(probed).

## 3. What was proven (with verbatim output)

### Query→node provenance (Task 2)

Layout + page with guard conditional + loop + nested partial with an N+1.
The provenance map, captured through a real controller request:

    (outside-template)                         -:0                    Board Load    boards:[1]
    t:153cecac9e4b/children2                   show.html.erb:2        Card Exists?
    t:153cecac9e4b/children2.statements1.body1 show.html.erb:4        Card Load     cards:[1, 2]
    t:c75dac150713/children0.body2             _card.html.erb:1       User Load,User Load  users:[2, 1]
    t:3c59c617daa9/children0.body3.body1.body1 application.html.erb:4 Board Count

Every distinction the hypothesis needed, demonstrated at once:
- **Controller reads vs render reads**: `Board.find` lands outside any node.
- **The guard's query vs the loop's query**: `cards.any?` attributes to the
  `if` node; the collection load attributes to the loop node *inside* it
  (asserted: distinct addresses, descendant relation).
- **The loop node owns the collection query and its loaded ids** (`cards:[1,2]`).
- **Per-iteration reads attribute inside the partial**, across template
  boundaries, accumulated over iterations (`users:[2,1]` on the
  `_card.html.erb` expression node).

### Divergence localization (Task 3)

Same dashboard rendered as an admin (with a sentinel name) and a regular user:

    differing: [layout html node, layout body node, dashboard guard, badge div, name expr]
    innermost: ["t:ecdd83461590/children2.statements1.body1"]   # <%= @viewer.name %>
    shared:    10 nodes  (heading, card list — byte-identical, sentinel-free)

The personal island is found *by evidence*, at expression granularity;
heading and card list are proven byte-shared. **Real discovery en route:**
AST paths cannot express cross-template containment — the layout's `<body>`
differs too, because it contains the yielded page. Localization had to be
computed on **output byte ranges** (each node's buffer segments mapped
through buffer-embedding into root coordinates); path-prefix containment is
insufficient the moment a layout or partial is involved.

### Structural addressing (Task 4)

Address = `t:<sha256(source)[0,12]>/<child-index path>`. Asserted: identical
address sets across re-renders and across a data change (new card inserted);
digest component changes when the source changes. No `dom_id`, no authoring.

### Rendering fidelity (re-verified on latest herb 0.10.3 + erubi 1.13.1)

- **Element/control/loop bracketing: byte-identical output** (asserted while
  the fidelity test ran against a fully-instrumented tree in the first run).
- Bracketing **`<%= %>` expression nodes** loses a newline. Standalone repro
  (`spike/trim_repro.rb`, single file, no upkeep code) pins down exactly
  what it is, verbatim output:

      A herb plain:            "a\n1\nb\n"
      B herb visitor-injected: "a\n1b\n"
      C herb literal tags:     "a\n1b\n"
      D erubi literal tags:    "a\n1\nb\n"
      B == C (injection == typing the tags):   true
      C == D (herb matches erubi on literal):  false

  Two conclusions: (1) **injection is NOT the cause** — visitor-injected
  tags behave exactly like tags typed in the source (B == C), so this is
  not an artifact of our bracketing approach; (2) **herb genuinely diverges
  from erubi**: for `...<%= 1 %><% :probe %>\nb`, herb trims the newline
  after a trailing code tag that does not start its line; erubi preserves
  it. Since ReActionView's premise is parity with stock ActionView (erubi),
  this is an upstream parity issue affecting even hand-written templates of
  this shape under `intercept_erb` — repro script is issue-ready, NOT filed
  (user submits externally). For upkeep the practical guidance is
  unchanged: bracket element/control nodes (byte-identical) and let
  expressions inherit their enclosing node's provenance.

### Overhead (Task 5)

Controller-free micro-bench (`spike/micro_bench.rb`, 50k renders × 6
order-alternated rounds, compiled template executed directly):

    plain compiled:                  3.580 us/render
    instrumented, capture OFF:       5.498 us/render  (+1.917)
    instrumented, capture ON:        9.151 us/render  (+5.571)
    per-node cost, capture OFF:      0.639 us
    per-node cost, capture ON:       1.857 us

A 100-instrumented-node page pays ~64µs always-on and ~186µs while
capturing — noise on any real page (Pulse's benchmark pages render in
milliseconds). Full-stack request benchmarks confirmed the same conclusion
but were dominated by controller/route-shape artifacts (±0.3–1.8ms swings
between structurally different routes, and ambient machine load); only the
same-shape ON/OFF delta and the micro-bench are trustworthy numbers.
Capture-off cost could be driven to ~zero by compiling two method bodies per
template (instrumented + plain) and dispatching per-request.

## 4. ReActionView/Herb maturity observations (from reading, not auditing)

- reactionview 0.3.0 is ~270 LOC of Ruby: handler + config + railtie +
  dev-tools assets. The engine substance lives in herb (native parser +
  ~700-LOC compiler). Small enough to understand fully; young enough to have
  no test-mode niceties (validation_mode defaults to :raise under test,
  :overlay elsewhere — the overlay injects `<template>` markup into pages).
- `intercept_erb` is **HTML-format-only** (`handlers/erb.rb:10`); json/text
  ERB templates keep stock ERB. Good for us (mirrors upkeep's HTML-only
  activation) but means a mixed pipeline exists.
- Engine `@optimize` path warns "output may differ from standard
  ActionView" (`engine.rb:86-90`) — leave it off; default path aims for
  parity and our byte-identical fidelity run supports that.
- Thread-safety: compilation happens under ActionView's template lock as
  usual; the engine instance is per-compile. Our thread-local shim is safe
  under concurrent compiles. `transform_visitors` shared instances are the
  one shared-mutable-state hazard (our visitor resets state per
  `visit_document_node`).
- ViewComponent: untested here. VC templates compile through their own
  pipeline; whether they route through the intercepted `:erb` handler needs
  a dedicated probe before betting Pulse's 17 components on it.
- The Gemfile route was blocked by a local bundler/asdf-shim issue
  (`bundle install` fails in this environment); gems installed directly.
  Immaterial to the findings.

## 5. Spike heuristics that must NOT ship as-is

- **Buffer embedding by substring search** (`Recording#absolute_ranges`):
  repeated partial renders map to the first occurrence; a tiny buffer could
  false-match. The real gem should link buffers explicitly (enter/leave
  around `render`/`yield` boundaries carrying parent buffer + offset).
- **Loop iterations share one node address** (segments accumulate). Fine
  for provenance; region-level *delivery* wants per-iteration identity
  (address + collection-member key) — the design already has the concept.
- **`sql.active_record` table extraction by regex** — spike-only; the real
  gem already gets tables/ids from the read-set hooks (prototype phase 1).
- Instrumenting **every** eligible node is the ceiling, not the plan: node
  selection (e.g. only nodes ≥ some subtree size, only collection/conditional
  boundaries) trades resolution for cost linearly.

## 6. Shortest path to region-level dependencies in the refresh-sync prototype

1. Add reactionview + the visitor (from this spike, minus expression-node
   bracketing) to the prototype's test app; keep the existing read-set
   hooks. Wire `Runtime.enter/leave` into the prototype's `Recording` so a
   read set becomes `{table/ids/predicates} × {node address}` instead of
   per-page. (~1 day of porting; the spike's runtime is already shaped for it.)
2. Registration: cohort rows gain `node_address` on each dependency entry;
   write matching unchanged (page-level refresh still the only delivery) —
   provenance is pure metadata until step 3.
3. Tier S v2: replace the whole-surface digest comparison with
   per-node text comparison (this spike's `localize_divergence`) — promotion
   then yields "shared page with personal islands" instead of a binary, and
   the scrubbed render only needs to prove the *shared remainder*.
4. Only then: region broadcast (Turbo Stream replace on
   `data-upkeep-node=<address>` stamped by the same visitor — compile-time,
   uniform, no authoring), for nodes whose dependencies changed.

Step 1–2 are safe immediately; 3–4 ride on evidence accumulated by 1–2.