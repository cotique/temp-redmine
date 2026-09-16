Feature to implement: $ARGUMENTS

Implement this feature. This step assumes /arch-check already returned SAFE TO IMPLEMENT.

Steps:
0. **Preflight, if this touches more than one repository or worktree.** In one
   batch, per repo: current branch, worktree list, short status. Echo the
   result back before the first edit. Sessions that span repos cost several
   times the tool calls and many times the corrections of single-repo work, and
   nearly all of it is branch/worktree/base identity confusion — ambient state
   that nobody re-reads once the conversation gets long.
1. Use only the abstractions and patterns identified by the architecture check. Do not introduce new patterns or abstractions unless the arch-check explicitly approved them.
2. Follow the naming conventions, file organization, and code style visible in the surrounding code.
3. Make the smallest change that fulfills the requirement. No refactoring of unrelated code, no error handling for impossible cases, no speculative abstractions.
4. When done, prove it works — and treat a green signal as a claim, not as proof:
   - Run existing tests if a test command is available.
   - **Canary rule:** before a green result becomes your evidence, make it go
     red on demand once. A signal you have never seen fail is not a signal.
     In practice: count *executed* cases, not registered ones; for pipelines
     compare the number of items processed against the number of inputs; for
     an HTTP probe check content-type and body size, not the status code; if
     you cannot make it fail, say the verification is unproven.
   - Show observable evidence (command, output, exact verification steps).
5. Report using this structure, in these four parts:
   - **Changed** — what you did, which files.
   - **Verified** — literally what you ran and what it printed. Only things
     you actually observed go here. Name which test exercises the changed
     path; if none does, say so in the same breath as "tests pass".
   - **Not verified, and why** — everything you could not check (no
     environment, missing fixture, needs a human). This section being empty
     is a claim in itself; make sure it's true.
   - **Yours next** — what the human has to decide, review, or run.

The words **done, complete, clean, ready to push** are prohibited unless a
build and a test run appear in the same turn, with their counts. A green suite
proves the changes didn't break what was already covered — not that the new
behavior works.

If you review your own diff, a zero-finding result is a **null result, not a
pass**: report it as "self-review found nothing, which is weak evidence on a
change like this," and say what an adversarial reviewer should look at.

If you get stuck:
- Do not retry the same approach repeatedly.
- Do not stack workarounds.
- Stop and run /stuck immediately.

Rules:
- **Write back what you learned.** If a knowledge base is configured and this
  task resolved something durable — the real cause behind a misleading symptom,
  an operational gotcha, a constraint discovered the hard way — record it, with
  its evidence tier. Findings that only ever flow *out* of a KB get re-derived
  or re-failed. Never write an `[INFERRED]` claim into a KB: a wrong entry
  costs every future session that trusts it.
- No commits or pushes unless explicitly asked.
- Never work directly on a protected branch.
- No comments that narrate what the code does — comment only when the WHY is non-obvious.
- No documentation files unless asked.
