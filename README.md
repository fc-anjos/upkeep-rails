# Upkeep Rails

Rails runtime for Upkeep. The repo currently contains the proof runner that
calibrates the Rails architecture around three structural inputs:

- Herb as the template-structure compiler.
- Active Record runtime observation as the data-dependency proof surface.
- Request, auth, and current-context reads as subscriber-specific delivery
  inputs.

The runner measures Herb against the maintained benchmark app templates in
`rails/upkeep/benchmark/upkeep-app/` and `rails/upkeep/benchmark/turbo-app/`,
then runs Active Record hook probes and in-memory end-to-end proofs.

## Layout

The runtime code lives under `lib/upkeep/`:

- `herb_loader.rb` loads the adjacent Herb checkout from `rails/view-stack/herb/`.
- `probes/herb_surface.rb` measures Herb parse, render-node, helper-lowering,
  fragment-root, and render-site coverage against benchmark templates.
- `probes/active_record_surface.rb` checks Rails 8.1 Active Record read and write
  observation hooks.
- `dependencies.rb` defines open dependency objects produced by observers.
- `dag.rb` stores generic nodes, edges, and dependency attachments.
- `replay.rb` stores per-target render recipes for page, render-site, and
  fragment replay.
- `runtime.rb` captures frame-scoped reads, request identity reads, and committed
  write facts.
- `domain.rb` defines the in-memory Rails domain used by the proofs.
- `templates.rb` defines page, partial, render-site, helper-hidden, and identity
  templates.
- `rendering.rb` renders tagged frames through ERB while recording runtime reads.
- `targeting.rb` selects update targets and applies extracted DOM patches.
- `proofs/end_to_end.rb` covers easy fragment updates, presenter/helper reads,
  collection membership, inline pages, helper-hidden collections, and plain
  preloaded data.
- `proofs/identity_safety.rb` covers subscriber-specific delivery where users
  have different visibility over the same card.
- `proofs/auth_surfaces.rb` covers Warden-style user reads, CurrentAttributes,
  session, cookie, and request dependencies.

## Run

```sh
MISE_TRUSTED_CONFIG_PATHS=/Volumes/FelipeSSD/professional/upkeep mise x ruby@3.4.7 -- ruby bin/run
```

The runner writes JSON reports to:

- `results/herb_surface.json`
- `results/active_record_surface.json`
- `results/end_to_end_proof.json`
- `results/identity_safety_proof.json`
- `results/auth_surfaces_proof.json`

## Current Question

Can Herb provide reliable compile-time frame plans for Rails templates while
Active Record and request identity observation remain authoritative for delivery
correctness?

The runner checks:

- strict Herb parse success for benchmark HTML ERB templates;
- render call extraction through `render_nodes: true`;
- helper-lowered elements through `action_view_helpers: true`;
- single-root partial eligibility for fragment boundary insertion;
- frontend tag plans for partial roots and render sites;
- Active Record relation execution, attribute reads, association loads,
  callback writes, and bulk writes;
- end-to-end DOM patch correctness through graph-driven narrow fragment,
  render-site, and page strategies;
- isolated target replay for page, render-site, and fragment frames;
- subscriber-specific patch extraction where two users share the same DOM target
  but require different payloads;
- ambient identity extraction from Warden-style user lookup, CurrentAttributes,
  session, cookies, and request reads.

Non-HTML ERB templates are outside this runner because Herb is being measured as
the HTML-aware template planner.
