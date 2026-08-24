# The scripted baseline's tuning sweep

`src/firm/llm.nim`'s `ShippedBaseline` is not a guess: it is the argmax of the grid sweep in
`tests/test_tuning.nim`, which plays seeded, all-scripted episodes through the shipped
`scriptedAction()` and ranks every candidate. This file is the record of that sweep; the sweep
itself runs in CI on every push (job `test`, both debug and `-d:release`), and its assertions are
the argmax claims below, so a constant that stops being the argmax turns CI red.

Reproduce locally with `nim r --hints:off --path:src tests/test_tuning.nim`.

## What is swept, and against what objective

**The objective** (pre-registered in the harness): the mean, over the evaluation episodes, of the
**weakest seat's score** — `min(manager score, the four worker scores)`. The design note calibrates
both score scales so that "both roles land near +1 when the firm is run well"
(design §Scoring, the 456-dollar worked shift), so the weakest seat at the table is what a
*competent* baseline has to mean: a baseline that is only worth playing in the role it happens to
draw is not one a prompt has to beat. Total surplus cannot serve here — payroll only moves money
between the manager and the workers, so surplus is blind to the pay rule entirely.

**Family S — the pace and the pay rule.** Every seat plays `steady` from shift 0.
Grid: `run` 0..10 × `maint` 0..(10 − run) × `payroll` {20, 25, …, 60} = **594 candidates**,
each over seeds {1, 7, 42} × horizons {8, 24} shifts.

**Family R — the nurse.** A window of shifts is played by `taskmaster` (run 10 / maint 0) and the
wrecked machine is then handed back to `steady` — the shape of a real mid-episode LLM fallback,
and the only way `condition < nurseBelow` is ever reached. (In an all-`steady` table the nurse
never fires: wear 18 against repair 18 holds every machine at exactly 100.) Two windows per
episode set: shifts 0–2 with the whole table wrecking, and shifts 3–5 with only machine 1's seat
wrecking. Grid: `nurseRun` 0..10 × `nurseMaint` 0..(10 − nurseRun) × `nurseBelow`
{20, 30, …, 90} = **528 candidates**, each over seeds {11, 23} × horizons {8, 24} shifts.

Both families are scored at two horizons (the fitted default of 8 shifts and the `MaxShifts` end at
24) so that a candidate cannot win by borrowing condition it never has to pay back.

## The result

Recorded from CI run
[32681924601](https://github.com/Metta-AI/cogame-firm/actions/runs/32681924601), job `test`
(debug and `-d:release` printed identical tables).

### Family S — pace and pay rule (594 candidates, best first)

```
  1. 0.9203  run 6 maint 3 payroll 40 nurse 0/8 below 70
  2. 0.9160  run 7 maint 3 payroll 40 nurse 0/8 below 70
  3. 0.9156  run 6 maint 4 payroll 40 nurse 0/8 below 70
  4. 0.8510  run 6 maint 3 payroll 45 nurse 0/8 below 70
  5. 0.8510  run 6 maint 4 payroll 45 nurse 0/8 below 70
  6. 0.8485  run 7 maint 3 payroll 45 nurse 0/8 below 70
  7. 0.8353  run 6 maint 3 payroll 35 nurse 0/8 below 70
  8. 0.8187  run 7 maint 2 payroll 40 nurse 0/8 below 70
  9. 0.7978  run 5 maint 3 payroll 40 nurse 0/8 below 70
  10. 0.7853  run 6 maint 4 payroll 35 nurse 0/8 below 70
```

(every family-S candidate carries the shipped nurse, which never fires in an all-`steady` table.)

`run 6 / maint 3 / payroll 40` is the **unique** argmax (the harness asserts the runner-up is
strictly worse), and it is the tuple the design note derived analytically — wear 3/hour against
repair 6/hour makes run 6 / maint 3 the sustainable pace (design.md §"Why the numbers are these
numbers"), and payroll 40 is where the manager's and the workers' scores meet. **Confirmed, not
changed.**

Two things the sweep shows that the arithmetic did not:

- `run 7 / maint 3` (0.9160) is *close*, and at the 8-shift horizon alone it wins: it produces
  more while the machines are fresh. It loses over the horizon set because the arithmetic catches
  up — 21 of wear against 18 of repair is −3 condition a shift, so by the 24-shift horizon the
  machine is deep into the `q = 0.5 + 0.5 × condition/100` penalty and every hour is worth less.
  That is why the sweep is scored at two horizons and not just the fitted default.
- `maint 4` is never better than `maint 3` at the same `run`: the extra repair hour buys nothing
  above the condition clamp and costs 1.5 of toil.

### Family R — the nurse (528 candidates)

Unconstrained best five:

```
  1. 0.7619  run 6 maint 3 payroll 40 nurse 10/0 below 20
  2. 0.7619  run 6 maint 3 payroll 40 nurse 10/0 below 30
  3. 0.7619  run 6 maint 3 payroll 40 nurse 10/0 below 40
  4. 0.7619  run 6 maint 3 payroll 40 nurse 10/0 below 50
  5. 0.7619  run 6 maint 3 payroll 40 nurse 10/0 below 60
```

Best among the repair-shaped candidates (`nurseMaint > nurseRun`), 240 of them:

```
  1. 0.7521  run 6 maint 3 payroll 40 nurse 0/8 below 70
  2. 0.7521  run 6 maint 3 payroll 40 nurse 0/8 below 80
  3. 0.7521  run 6 maint 3 payroll 40 nurse 0/8 below 90
  4. 0.7485  run 6 maint 3 payroll 40 nurse 0/9 below 80
  5. 0.7485  run 6 maint 3 payroll 40 nurse 0/9 below 90
  6. 0.7448  run 6 maint 3 payroll 40 nurse 0/10 below 80
  7. 0.7448  run 6 maint 3 payroll 40 nurse 0/10 below 90
  8. 0.7292  run 6 maint 3 payroll 40 nurse 0/10 below 20
  9. 0.7292  run 6 maint 3 payroll 40 nurse 0/10 below 30
  10. 0.7292  run 6 maint 3 payroll 40 nurse 0/10 below 40
  the design note's nurse (run 4 / maint 6 below 40): 0.6297 — rank 130 of 240
```

**Adopted: `nurseRun 0 / nurseMaint 8 / nurseBelow 70`** — a wrecked machine spends one whole shift
in the shop and comes back at full condition. This is a **disclosed deviation from the design
note**, which specifies "if `condition < 40` then `run = 4, maint = 6`" (design.md §Scripted
baselines). The note's drip repair is dominated on every horizon: at +24 condition a shift it takes
four shifts to climb back from a taskmaster wreck, and it produces at a badly degraded quality
the whole way, while 8 hours of repair (48 condition) restores the machine in one. Repairing at 8 hours
rather than 10 buys the same clamped 100 for 3 less toil, which is why `0/8` beats `0/10`; the
threshold plateaus at 70/80/90 (the harness's stable sort takes the smallest, 70) because a
machine handed back by a taskmaster is far below any of them.

The unconstrained argmax, `nurse 10/0`, is 1.3 % better still and is **not** adopted: it is not a
nurse at all — it says "thrash the dying machine", which is the `taskmaster` foil's move, and it
would erase the difference between the two shipped baselines that makes a two-baseline table
something other than a mirror match. The design note fixes the *shape* of the branch ("nurse the
machine"); the sweep fixes its *numbers*. That constraint is stated in the harness and the
unconstrained table is printed beside the constrained one, so nothing is hidden by it.

`TaskmasterPayroll = 20` is deliberately not swept: `taskmaster` is the foil, not a tuned baseline.
Its pay rule is fixed *below* the worker's $1.50/hour indifference point by construction so that a
worker who obeys it is provably underpaid.

## What the sweep does not settle

- The evaluation is against the scripted table, not against an LLM opponent. It says the shipped
  dials are the best *scripted* play on this grid; a hosted episode (phase 60) is what says how a
  prompt does against them.
- Family R's ranking is flat near the top — the two ends of the grid (`10/0` and `0/8`) are 1.3 %
  apart and everything between them is worse than both. The nurse is therefore the least
  identified of the dials, which is why the harness prints the whole shape of the table rather
  than only its argmax.
