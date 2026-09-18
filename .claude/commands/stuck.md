Stop all implementation work immediately.

Do NOT attempt a fix. Do NOT try another approach. Do NOT write any code.

**Trigger (two-guess rule):** two failed attempts of the same *kind* mean the
kind is wrong, not the attempt. Reading a third file the same way, tweaking a
third variant of the same call, grepping a third synonym — that's the same
guess wearing a hat. At that point either change the class of source (code →
running system, docs → KB, local → CI) or run this command. Don't wait for
attempt five.

**When a hypothesis is refuted, the next move is a measurement — not another
hypothesis.** The failure pattern this command exists to break is: get
objected to, absorb the objection as a new prior, produce the nearest
alternative story, repeat. A root cause that migrates under social pressure
rather than under new evidence is not converging on anything. The correct
output after being wrong twice is *"unknown — here is the check that settles
it."*

Diagnose only:

1. State what you were trying to do.
2. State exactly where you are stuck — the specific line, method, interface, or behavior blocking progress.
3. State why — the root cause, not the symptom.
4. Present 2-3 distinct resolution options with tradeoffs:
   - Option A: [approach] — [tradeoff]
   - Option B: [approach] — [tradeoff]
   - Option C (if applicable): [approach] — [tradeoff]
5. Recommend one option in a single sentence.
6. End with: "Waiting for direction before proceeding."

Rules:
- No code changes in this step.
- Do not express confidence that one more attempt will fix it.
- If the root cause needs architectural input (new table, new service, new abstraction), say so explicitly — that decision belongs to a human.
