Feature to check: $ARGUMENTS

Run an architecture check BEFORE any implementation. Do NOT write code in this step.

Steps:
1. If a knowledge-base MCP tool is configured, query it for existing patterns, components, and prior decisions related to this feature.
2. Read the README and any docs covering the affected module.
3. If a code graph is configured (see `discipline.json` → `codeGraph`), use it for the impact map: what depends on the components you'd touch, and what they depend on. Query it **structurally, not conversationally** — resolve the exact node by name, confirm it is the one you meant, and only then ask for neighbors or paths. A natural-language question traverses from whatever the phrasing matched and returns a confident answer from the wrong subgraph if the seed was wrong. A traversal counts as `[OBSERVED]` only when the seed was verified; seeded from a guess it is `[INFERRED]`. Check the graph's build commit against `HEAD` too — a stale graph describes structure that no longer exists and shows no sign of it.
4. Search the codebase for existing abstractions, base classes, helpers, or components this feature could build on.
5. Determine the canonical implementation path:
   - Which existing primitives, services, or patterns should be used?
   - Where does this fit in the current architecture?
   - Which files would change or be added?

6. In a multi-repo setup: if the touched code is a published package (NuGet/npm/etc.), list the known downstream consumers and state whether the change is contract-breaking. A breaking package change is automatically **NEEDS NEW ARCHITECTURE** territory unless the migration path for consumers is part of the design.

7. Return exactly one of two verdicts:

   **SAFE TO IMPLEMENT**
   > Uses existing: [specific abstractions/components]
   > Proposed approach: [2-3 sentence design]
   > Files to touch: [list]
   > Proceed with: /implement [feature]

   **NEEDS NEW ARCHITECTURE**
   > This requires building something new: [what]
   > Reason: [why existing patterns don't cover it]
   > STOP — do not proceed. Escalate to a human reviewer before implementing.

Rules:
- Never write implementation code here.
- On NEEDS NEW ARCHITECTURE, halt completely. No workarounds, no "quick prototypes".
- If the feature description is ambiguous, ask one clarifying question before checking.
- **Tag every claim with its evidence tier** (see below). An untagged claim is
  an `[INFERRED]` one that forgot to say so.
- **"I didn't find it" is not "it doesn't exist."** A negative finding — no
  existing abstraction, no prior decision — must show the searches that came
  back empty, or it doesn't count as a finding.
- **Write the falsifier before the conclusion.** For each causal claim in the
  verdict, one line: *"this is wrong if ___"* — then check that before
  presenting. A claim with no falsifier drifts toward whatever the human last
  objected to.
- **Simplicity first.** The proposed approach is the minimum that solves the
  stated problem. No speculative features, no abstractions for single-use
  code, no "flexibility" or "configurability" that wasn't asked for.
- **Surgical changes.** The files-to-touch list contains only what the
  feature requires. Don't propose refactoring, reformatting, or "improving"
  adjacent code that isn't broken — cleanup scope is limited to the mess this
  feature itself would make.

## Evidence tiers

Every causal or state claim names its source class. This is syntactic, not a
style preference: reading code and observing behavior *feel identical* once a
line number is attached, and the attached line number is what makes an
unverified claim feel audited.

| Tag | Means |
|---|---|
| `[OBSERVED: cmd → result]` | You ran it, read the log line, queried the store, captured the payload |
| `[READ: path:line]` | You read the source that implements it |
| `[INFERRED: from naming/types/convention]` | You reasoned. Nothing was read or run |
| `[KB: doc]` | Retrieved from the knowledge base — inherits whatever tier it was written with, which may be none |

Hard rules:

- `[INFERRED]` may **never** appear in a PR description, an RCA, a knowledge-base
  write, or a reply to a human reviewer. Upgrade it or drop it.
- Anything about a **provider, runtime, deployment topology, or remote state**
  requires `[OBSERVED]` or an explicit "I have no verified source for this."
  Local source cannot contradict a plausible story about a remote system, so
  nothing in context will stop you.
- Behavior inferred from a **name** is `[INFERRED]`, always. `regenerates()`
  may not regenerate; a field named in a schema may not exist; "every call site
  does X" is a count, and counts are `[OBSERVED]`.
