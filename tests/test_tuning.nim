## The grid-tuning harness for the scripted `steady` baseline.
##
## Review finding F1 (round 1): the baseline's dials were justified
## analytically in the design note but never swept, so "tuned with a grid
## harness, not guessed" could not be checked from the tree. This file IS the
## sweep. It plays seeded, all-scripted episodes through the shipped
## `scriptedAction` over a bounded parameter grid and asserts that
## `ShippedBaseline` is the argmax. Its recorded output is
## `docs/baseline-sweep.md`; because the assertions below are the sweep, a
## constant that stops being the argmax turns CI red.
##
## THE OBJECTIVE (pre-registered, one number per candidate): the mean over the
## evaluation episodes of the WEAKEST seat's score,
## `min(manager score, the four worker scores)`. The design note calibrates
## both score scales so that "both roles land near +1 when the firm is run
## well" (design §Scoring), so the weakest seat at the table is what
## "competent baseline" has to mean here: a baseline that is only worth
## playing in the role it happens to draw is not a baseline a prompt has to
## beat. Note that total surplus cannot serve as the objective — payroll only
## moves money between the manager and the workers, so surplus is blind to it.
##
## TWO SCENARIO FAMILIES, because the two halves of the policy are reached by
## different episodes:
##
##   S (pace and pay rule): every seat plays `steady` from shift 0. Identifies
##     `run`, `maint` and `payroll`. The nurse branch never fires here — a
##     steady machine holds at condition 100 — which is exactly why R exists.
##   R (the nurse): a window of shifts in which seats play `taskmaster`
##     (run 10 / maint 0) and then hand the wrecked machine back to `steady`.
##     That is the shape of the real mid-episode LLM fallback and the only way
##     `condition < nurseBelow` is ever reached. Candidates are ranked among
##     the repair-shaped ones (`nurseMaint > nurseRun`): the design note fixes
##     the SHAPE of that branch ("nurse the machine"), the sweep fixes its
##     numbers. The unconstrained top of the table is echoed too, so the
##     result of dropping that constraint is on the record rather than hidden.
##
## Both families are evaluated at two horizons (the fitted default of 8 shifts
## and the `MaxShifts` end at 24) so a candidate cannot win by borrowing from
## a machine it never has to pay back.

import std/[algorithm, strutils, unittest]
import firm/[llm, sim]

const
  PaceSeeds = [1, 7, 42]
  NurseSeeds = [11, 23]
  Horizons = [8, 24]
  PayrollGrid = [20, 25, 30, 35, 40, 45, 50, 55, 60]
  NurseBelowGrid = [20, 30, 40, 50, 60, 70, 80, 90]
  Tie = 1e-9

type
  Row = object
    score: float
    params: BaselineParams

proc fixture(seed, shifts: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.shifts = shifts
  result.reports = true
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc weakestScore(config: GameConfig, params: BaselineParams,
    wreckFrom, wreckTo: int, wreckAll: bool): float =
  ## One whole episode played by the scripted baselines, scored by its worst
  ## seat. Inside `[wreckFrom, wreckTo]` the wrecking seats play `taskmaster`
  ## (all five when `wreckAll`, otherwise only the seat holding machine 1);
  ## everywhere else every seat plays `steady` with `params`.
  var sim = initSim(config)
  while not sim.done:
    let shift = sim.shift
    let wrecking = shift >= wreckFrom and shift <= wreckTo
    for seat in sim.orderedSeats():
      let kind =
        if wrecking and (wreckAll or seat == sim.workerSeat[0]): skTaskmaster
        else: skSteady
      let decision = scriptedAction(sim, seat, kind, params)
      if sim.isManager(seat):
        sim.applyMemo(seat, decision.orders, decision.payroll, decision.split,
          decision.say, decision.notes, true)
      else:
        sim.applyWork(seat, decision.line, decision.run, decision.maint,
          decision.say, decision.notes, true)
  doAssert sim.reason == "complete"
  result = sim.score(0)
  for seat in 1 ..< Seats:
    result = min(result, sim.score(seat))

proc familyS(params: BaselineParams): float =
  var total = 0.0
  var episodes = 0
  for seed in PaceSeeds:
    for shifts in Horizons:
      total += weakestScore(fixture(seed, shifts), params, -1, -1, true)
      inc episodes
  total / episodes.float

proc familyR(params: BaselineParams): float =
  var total = 0.0
  var episodes = 0
  for seed in NurseSeeds:
    for shifts in Horizons:
      ## The whole table wrecks early, then recovers; and one seat wrecks
      ## mid-episode while the rest of the floor keeps working.
      total += weakestScore(fixture(seed, shifts), params, 0, 2, true)
      total += weakestScore(fixture(seed, shifts), params, 3, 5, false)
      episodes += 2
  total / episodes.float

proc byScoreDesc(a, b: Row): int =
  ## Descending by score. Nim's sort is stable, so a plateau keeps the grid's
  ## own ascending order and the tie-break is the smallest candidate.
  cmp(b.score, a.score)

proc line(row: Row): string =
  let p = row.params
  formatFloat(row.score, ffDecimal, 4) & "  run " & $p.run & " maint " &
    $p.maint & " payroll " & $p.payroll & " nurse " & $p.nurseRun & "/" &
    $p.nurseMaint & " below " & $p.nurseBelow

proc echoTop(title: string, rows: seq[Row], count: int) =
  echo title, " (", rows.len, " candidates, best first)"
  for index in 0 ..< min(count, rows.len):
    echo "  ", index + 1, ". ", rows[index].line()

suite "baseline grid sweep":
  test "family S: the shipped pace and pay rule are the sweep's argmax":
    var rows: seq[Row]
    for run in 0 .. ShiftHours:
      for maint in 0 .. ShiftHours - run:
        for payroll in PayrollGrid:
          var params = ShippedBaseline
          params.run = run
          params.maint = maint
          params.payroll = payroll
          rows.add(Row(score: familyS(params), params: params))
    rows.sort(byScoreDesc)
    echoTop("family S — pace and pay rule", rows, 10)
    let best = rows[0].params
    check best.run == ShippedBaseline.run
    check best.maint == ShippedBaseline.maint
    check best.payroll == ShippedBaseline.payroll
    ## A unique argmax, not a plateau the shipped tuple merely sits on.
    check rows[1].score < rows[0].score - Tie

  test "family R: the shipped nurse is the sweep's argmax among repairs":
    var rows: seq[Row]
    for nurseRun in 0 .. ShiftHours:
      for nurseMaint in 0 .. ShiftHours - nurseRun:
        for below in NurseBelowGrid:
          var params = ShippedBaseline
          params.nurseRun = nurseRun
          params.nurseMaint = nurseMaint
          params.nurseBelow = below
          rows.add(Row(score: familyR(params), params: params))
    rows.sort(byScoreDesc)
    echoTop("family R — the nurse, unconstrained", rows, 5)
    var repairs: seq[Row]
    for row in rows:
      if row.params.nurseMaint > row.params.nurseRun:
        repairs.add(row)
    echoTop("family R — the nurse, repair-shaped (nurseMaint > nurseRun)",
      repairs, 10)
    ## Where the design note's own nurse lands, for the record.
    for index, row in repairs:
      if row.params.nurseRun == 4 and row.params.nurseMaint == 6 and
          row.params.nurseBelow == 40:
        echo "  the design note's nurse (run 4 / maint 6 below 40): ",
          formatFloat(row.score, ffDecimal, 4), " — rank ", index + 1, " of ",
          repairs.len
    let best = repairs[0].params
    check best.nurseRun == ShippedBaseline.nurseRun
    check best.nurseMaint == ShippedBaseline.nurseMaint
    check best.nurseBelow == ShippedBaseline.nurseBelow

  test "the shipped baseline is legal everywhere on the grid it was tuned on":
    ## The sweep only means something if every candidate it scored was a legal
    ## episode: an illegal move would have raised out of applyMemo/applyWork
    ## above. This pins the shipped tuple's own episode explicitly.
    for seed in PaceSeeds:
      let config = fixture(seed, 8)
      var sim = initSim(config)
      while not sim.done:
        for seat in sim.orderedSeats():
          let decision = scriptedAction(sim, seat, skSteady, ShippedBaseline)
          if sim.isManager(seat):
            check decision.payroll in 0 .. MaxPayrollPercent
            sim.applyMemo(seat, decision.orders, decision.payroll,
              decision.split, decision.say, decision.notes, true)
          else:
            check decision.run in 0 .. ShiftHours
            check decision.maint in 0 .. ShiftHours
            check decision.run + decision.maint <= ShiftHours
            sim.applyWork(seat, decision.line, decision.run, decision.maint,
              decision.say, decision.notes, true)
      check sim.reason == "complete"
      check sim.shiftsPlayed == config.shifts
