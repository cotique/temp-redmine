Feature to orchestrate: $ARGUMENTS

Design this feature and produce a ready-to-paste implementation prompt for a separate worker session. Do NOT implement anything yourself.

Steps:
1. If a knowledge-base MCP tool is configured, query it for relevant patterns and prior decisions.
2. Read the README and relevant docs.
3. Identify the canonical implementation path using existing abstractions (same bar as /arch-check).
4. If this requires new architecture: say so clearly and stop — do not produce an implementation prompt.
5. Design the solution:
   - Which existing components/patterns to use
   - Which files to create or modify
   - What the change looks like at a high level
6. Write an exact, self-contained prompt for a worker session. The worker has zero context from this conversation, so include:
   - What to build (specific, scoped)
   - Which existing abstractions/patterns to use, by name
   - Which files to touch
   - How to verify it works
   - Constraints (no new patterns, no commits, etc.)

Output format:
---
**Design summary:** [2-3 sentences]

**Worker prompt:**
```
[paste-ready prompt]
```
---
