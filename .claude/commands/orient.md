Orient yourself in this project before doing any work.

1. Locate and read the README (repo root, `docs/`, `documentation/`).
2. Read every CLAUDE.md you can find (root and subdirectories).
3. If a knowledge-base MCP tool is configured for this project, query it for an architecture overview.
4. If a code graph is configured (see `discipline.json` → `codeGraph`), pull the top-level module/dependency graph instead of guessing structure from folder names. Ask it structurally (named nodes, their neighbors) rather than in prose, and note the graph’s build commit — if it lags `HEAD`, treat what it tells you as dated.
5. In a multi-repo setup: read the package manifest (`.csproj`/`Directory.Packages.props`, `package.json`, ...) and note which dependencies are sibling packages owned by this team — changes here may ripple to other repos.
6. From what you read, identify:
   - The main architectural layers and what each is responsible for
   - Key abstractions, base classes, or patterns the codebase enforces
   - Naming conventions and file-organization rules
   - Any explicit "do not do X" rules documented anywhere

7. Output a concise summary:
   - Project purpose (one sentence)
   - Key abstractions (bullet list)
   - Patterns to follow
   - Anything flagged as off-limits or requiring special care

8. End with: "I am oriented. Ready to proceed — please run /arch-check before any new feature work."

Constraints:
- Do not read every file in the repo — stick to README, CLAUDE.md, docs, and the KB.
- Do not write any code in this step.
- Tag each claim with its evidence tier — `[OBSERVED]` / `[READ: path:line]` /
  `[INFERRED]` / `[KB]` (see `/arch-check` for the definitions) — so the next
  stage knows what was run, what was read, and what was guessed from names.
- Docs go stale. When a doc and the code disagree, say both and flag the
  conflict; don't silently prefer the tidier one.
- Batch independent reads. Five files, three greps, or several repos' git state
  belong in one message, not five round trips.
- Prefer the dedicated search tools over shelling out to `grep`/`find` — they
  are faster, quieter in context, and don't trigger permission prompts.
