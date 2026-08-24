## Pure game rules for Firm: one manager who sees the market, four workers
## who see the machines. No IO, no networking, no LLM — the server, the
## tests, and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: the seeded seat→role permutation, the hidden
## order board, the four machines, the live shift's decisions, each seat's
## private notes, and the append-only event log. Everything random is drawn
## from the seed at `initSim`, so a replay re-derives the episode from the
## recorded memo and work events alone.

import std/[json, math, random, strutils, unicode], types

export types

const
  ShiftHours* = 10
  UnitsPerHour* = 2.0
  ChangeoverHours* = 2
  WearPerRunHour* = 3
  RepairPerMaintHour* = 6
  MaxCondition* = 100
  Price* = 10.0
  SalvagePrice* = 2.0
  ToilPerHour* = 1.5
  MaxPayrollPercent* = 60
  InitialPayrollPercent* = 30
  WorkerScoreScale* = 30.0
  ManagerScoreScale* = 300.0
  MinShifts* = 4
  MaxShifts* = 24
  ## Worst case per shift: one batch plus one retry batch, each bounded by
  ## llmTimeoutSeconds (30).
  ShiftBudgetSeconds* = 60
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 20_000
  ## Share of the platform's episode timeout spent playing.
  PlayBudgetFraction* = 0.6
  MaxDirectiveLen* = 240
  MaxReportLen* = 120
  RoleNames* = ["Manager", "Worker"]
  LineNames* = ["A", "B"]
  StandingOrder* = "Standing order: machines 1-3 on line A, machine 4 on " &
    "line B. Six hours running, three on maintenance."
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]

type
  Phase* = enum
    phShift = "shift"    ## the open shift is waiting for its five decisions
    phDone = "done"

  Sim* = object
    config*: GameConfig
    names*: seq[string]              ## anonymous cog aliases per seat
    roleOf*: array[Seats, int]       ## seat -> 0 Manager | 1 Worker
    managerSeat*: int
    workerSeat*: array[Machines, int]
    workerIndex*: array[Seats, int]  ## worker seats -> 0..3; manager -> -1
    demandA*, demandB*: seq[int]     ## HIDDEN from workers; length shifts + 2
    switchShift*: int
    machines*: array[Machines, MachineState]
    payroll*: int                    ## in force this shift
    split*: array[Machines, int]     ## in force this shift, sums to 100
    directive*: string               ## the standing directive in force
    nextOrders*: array[Machines, string] ## announced this shift, in force next
    nextPayroll*: int
    nextSplit*: array[Machines, int]
    lines*: array[Machines, string]  ## this shift's chosen line; "" = undecided
    runs*, maints*: array[Machines, int]   ## this shift; -1 = undecided
    reports*: array[Machines, string]      ## this shift's worker reports
    heardReports*: array[Machines, string] ## last shift's, read by the manager
    memoDone*: bool                  ## the manager has acted this shift
    scriptedSeat*: array[Seats, bool] ## seat's last applied decision was a
                                     ## baseline's, not a reply's
    notes*: seq[string]              ## latest private notes per seat
    history*: seq[ShiftResult]       ## one record per resolved shift
    board*: seq[tuple[a, b: int]]    ## realized demand, shifts 0 .. shift
    workerNet*: array[Machines, float]
    workerUnits*: array[Machines, int]
    firmProfit*, firmRevenue*, firmWages*: float
    shift*, shiftsPlayed*: int
    phase*: Phase
    done*: bool
    reason*: string                  ## "complete" | "deadline"
    events*: seq[GameEvent]

# ---- Helpers ----------------------------------------------------------------

proc machineLabel*(worker: int): string =
  ## Machines are numbered 1..4 for humans; a spectator reads MACHINE 3.
  "Machine " & $(worker + 1)

proc trimText*(text: string, limit: int): string =
  ## Strip, collapse newlines, and cut on a RUNE boundary: a byte slice
  ## through a multi-byte character would leave invalid UTF-8 in the replay
  ## and break its JSON.
  result = text.strip().replace("\r", " ").replace("\n", " ")
  if result.runeLen > limit:
    result = result.runeSubStr(0, limit)

proc normalizeSplit*(values: seq[float]): array[Machines, int] =
  ## Four non-negative shares renormalized to integers summing to exactly
  ## 100 by largest remainder, ties broken by ascending index. All-zero (or
  ## missing) is an equal split.
  var clean: array[Machines, float]
  var total = 0.0
  for index in 0 ..< Machines:
    let value = if index < values.len: values[index] else: 0.0
    clean[index] = max(0.0, value)
    total += clean[index]
  if total <= 0.0:
    return [25, 25, 25, 25]
  var remainder: array[Machines, float]
  var used = 0
  for index in 0 ..< Machines:
    let exact = 100.0 * clean[index] / total
    result[index] = int(floor(exact))
    remainder[index] = exact - result[index].float
    used += result[index]
  var left = 100 - used
  while left > 0:
    var best = 0
    for index in 1 ..< Machines:
      if remainder[index] > remainder[best] + 1e-12:
        best = index
    result[best] += 1
    remainder[best] = -1.0
    dec left

proc normalizeLine*(text: string): string =
  ## "a", "A", "line a", " Line A " all resolve to "A"; anything else is "".
  let clean = text.strip().toLowerAscii()
  case clean
  of "a", "line a", "product line a", "linea": "A"
  of "b", "line b", "product line b", "lineb": "B"
  else: ""

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the floor: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed so replays
  ## and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the shift count into the episode's play budget. Idempotent: a
  ## config that already carries the cap (a replay being re-read) is
  ## untouched.
  result = config
  if result.sampled:
    return
  let budget = PlayBudgetFraction * config.episodeTimeoutSeconds.float -
    config.playerConnectTimeoutSeconds - PacingBudgetMs.float / 1000.0
  let fitted = int(budget / ShiftBudgetSeconds.float)
  result.shifts = max(MinShifts, min(config.shifts, min(MaxShifts, fitted)))
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.shifts, 1))
  result.sampled = true

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, shift: -1, seat: -1, worker: -1, run: -1, maint: -1,
    demandA: -1, demandB: -1, payroll: -1, soldA: -1, soldB: -1,
    surplusA: -1, surplusB: -1)

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc logShift(sim: var Sim) =
  var event = blankEvent(evShift)
  event.shift = sim.shift
  event.demandA = sim.demandA[sim.shift]
  event.demandB = sim.demandB[sim.shift]
  for worker in 0 ..< Machines:
    event.machines.add(sim.machines[worker])
    event.split.add(sim.split[worker])
  event.payroll = sim.payroll
  event.text = sim.directive
  sim.addEvent(event)

proc openShift(sim: var Sim) =
  ## The next shift becomes live: the manager's last announcement takes
  ## effect, last shift's reports move where the manager can read them, and
  ## the five decisions are due.
  for worker in 0 ..< Machines:
    sim.machines[worker].order = sim.nextOrders[worker]
  sim.payroll = sim.nextPayroll
  sim.split = sim.nextSplit
  sim.heardReports = sim.reports
  sim.reports = ["", "", "", ""]
  sim.lines = ["", "", "", ""]
  sim.runs = [-1, -1, -1, -1]
  sim.maints = [-1, -1, -1, -1]
  sim.memoDone = false
  sim.phase = phShift
  sim.board.add((a: sim.demandA[sim.shift], b: sim.demandB[sim.shift]))
  sim.logShift()

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(FirmError, "firm needs exactly " & $Seats & " players")
  if config.shifts < MinShifts:
    raise newException(FirmError, "shifts must be at least " & $MinShifts)
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  ## One stream for everything the seed decides, in this fixed order: roles,
  ## the two demand levels, the switch shift. (Aliases come from the seed
  ## too, on tableNames' own stream.)
  var rng = initRand(int64(config.seed) * 7919 + 17)
  var roles = @[0, 1, 1, 1, 1]
  rng.shuffle(roles)
  var worker = 0
  for seat in 0 ..< Seats:
    result.roleOf[seat] = roles[seat]
    if roles[seat] == 0:
      result.managerSeat = seat
      result.workerIndex[seat] = -1
    else:
      result.workerSeat[worker] = seat
      result.workerIndex[seat] = worker
      inc worker
  let highDemand = rng.rand(30 .. 36)
  let lowDemand = rng.rand(12 .. 18)
  result.switchShift = rng.rand(3 .. 5)
  ## The board runs one shift past the last so the manager's one-shift
  ## lookahead is defined on the final shift.
  for shift in 0 .. config.shifts + 1:
    if shift < result.switchShift:
      result.demandA.add(highDemand)
      result.demandB.add(lowDemand)
    else:
      result.demandA.add(lowDemand)
      result.demandB.add(highDemand)
  const InitialSetups = ["A", "A", "A", "B"]
  for index in 0 ..< Machines:
    result.machines[index] = MachineState(
      setup: InitialSetups[index],
      order: InitialSetups[index],
      condition: MaxCondition
    )
    result.nextOrders[index] = InitialSetups[index]
  result.nextPayroll = InitialPayrollPercent
  result.nextSplit = [25, 25, 25, 25]
  result.directive = StandingOrder
  result.notes = newSeq[string](Seats)
  result.shift = 0
  result.addEvent(blankEvent(evStart))
  result.openShift()

# ---- Queries ----------------------------------------------------------------

proc roleName*(sim: Sim, seat: int): string =
  RoleNames[sim.roleOf[seat]]

proc isManager*(sim: Sim, seat: int): bool =
  sim.roleOf[seat] == 0

proc pendingSeats*(sim: Sim): seq[int] =
  ## Every seat that has not acted this shift, in seat order. Empty once
  ## the episode is over.
  if sim.done:
    return
  for seat in 0 ..< Seats:
    if sim.isManager(seat):
      if not sim.memoDone:
        result.add(seat)
    elif sim.lines[sim.workerIndex[seat]].len == 0:
      result.add(seat)

proc orderedSeats*(sim: Sim): seq[int] =
  ## The order decisions are APPLIED in: the manager first, then workers
  ## 0..3. The machine ordering in the record depends on the seeded role
  ## draw, never on slot numbering.
  let pending = sim.pendingSeats()
  for seat in pending:
    if sim.isManager(seat):
      result.add(seat)
  for worker in 0 ..< Machines:
    let seat = sim.workerSeat[worker]
    if seat in pending:
      result.add(seat)

proc score*(sim: Sim, seat: int): float =
  ## Higher is better everywhere. A worker scores its take-home pay net of
  ## the effort it cost; the manager scores the firm's profit. Both are
  ## normalized per shift so the ladder is not a lottery over role draws.
  if sim.shiftsPlayed == 0:
    return 0.0
  let shifts = sim.shiftsPlayed.float
  if sim.isManager(seat):
    sim.firmProfit / (shifts * ManagerScoreScale)
  else:
    sim.workerNet[sim.workerIndex[seat]] / (shifts * WorkerScoreScale)

# ---- Play -------------------------------------------------------------------

proc settle(sim: var Sim, reason: string) =
  sim.done = true
  sim.reason = reason
  sim.phase = phDone
  var event = blankEvent(evEnd)
  event.shift = sim.shiftsPlayed
  event.text = reason
  sim.addEvent(event)

proc resolveShift(sim: var Sim) =
  ## All five decisions are in: the shift runs, the goods are sold and the
  ## payroll is paid. Deterministic — no randomness anywhere.
  var record = ShiftResult(shift: sim.shift)
  var producedA = 0
  var producedB = 0
  for worker in 0 ..< Machines:
    let startCondition = sim.machines[worker].condition
    let line = sim.lines[worker]
    let runHours = sim.runs[worker]
    let maintHours = sim.maints[worker]
    let changeover = line != sim.machines[worker].setup
    let hours = max(0, runHours - (if changeover: ChangeoverHours else: 0))
    sim.machines[worker].setup = line
    let quality = 0.5 + 0.5 * startCondition.float / MaxCondition.float
    let units = int(floor(UnitsPerHour * hours.float * quality))
    let after = clamp(
      startCondition - WearPerRunHour * hours + RepairPerMaintHour * maintHours,
      0, MaxCondition)
    let toil = ToilPerHour * (runHours + maintHours).float
    sim.machines[worker].condition = after
    sim.machines[worker].run = runHours
    sim.machines[worker].maint = maintHours
    sim.machines[worker].units = units
    sim.machines[worker].toil = toil
    record.line[worker] = line
    record.run[worker] = runHours
    record.maint[worker] = maintHours
    record.units[worker] = units
    record.condition[worker] = after
    record.toil[worker] = toil
    record.obeyed[worker] = line == sim.machines[worker].order
    record.idle[worker] = runHours == 0
    if line == "A": producedA += units else: producedB += units
    sim.workerUnits[worker] += units
  ## Sell against the board; anything beyond demand is scrap.
  record.soldA = min(producedA, sim.demandA[sim.shift])
  record.soldB = min(producedB, sim.demandB[sim.shift])
  record.surplusA = producedA - record.soldA
  record.surplusB = producedB - record.soldB
  record.revenue = Price * (record.soldA + record.soldB).float +
    SalvagePrice * (record.surplusA + record.surplusB).float
  ## Pay out of the pool the manager set for THIS shift.
  record.pool = record.revenue * sim.payroll.float / 100.0
  record.profit = record.revenue - record.pool
  for worker in 0 ..< Machines:
    let pay = record.pool * sim.split[worker].float / 100.0
    record.pay[worker] = pay
    sim.machines[worker].pay = pay
    sim.workerNet[worker] += pay - record.toil[worker]
  sim.firmRevenue += record.revenue
  sim.firmWages += record.pool
  sim.firmProfit += record.profit
  sim.history.add(record)

  var event = blankEvent(evSettle)
  event.shift = record.shift
  for worker in 0 ..< Machines:
    event.units.add(record.units[worker])
    event.condition.add(record.condition[worker])
    event.pay.add(record.pay[worker])
    event.toil.add(record.toil[worker])
    event.obeyed.add(record.obeyed[worker])
    event.idle.add(record.idle[worker])
  event.soldA = record.soldA
  event.soldB = record.soldB
  event.surplusA = record.surplusA
  event.surplusB = record.surplusB
  event.revenue = record.revenue
  event.pool = record.pool
  event.profit = record.profit
  sim.addEvent(event)

  inc sim.shiftsPlayed
  inc sim.shift
  if sim.shiftsPlayed >= sim.config.shifts:
    ## The settle event already carries the post-shift machine state, so
    ## `end` follows it directly — there is no trailing `shift` event.
    sim.settle("complete")
  else:
    sim.openShift()

proc maybeResolve(sim: var Sim) =
  if not sim.done and sim.pendingSeats().len == 0:
    sim.resolveShift()

proc applyMemo*(sim: var Sim, seat: int, orders: seq[string], payroll: int,
    split: seq[int], directive, notes: string, scripted: bool) =
  ## The manager files its memo: the lines each machine is ordered onto, the
  ## pay rule, and one short directive. Everything here takes effect NEXT
  ## shift; nothing the manager writes in shift s binds anybody in shift s.
  if sim.done:
    raise newException(FirmError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(FirmError, "bad seat: " & $seat)
  if not sim.isManager(seat):
    raise newException(FirmError, sim.names[seat] & " is not the manager")
  if sim.memoDone:
    raise newException(FirmError,
      sim.names[seat] & " has already filed a memo this shift")
  if payroll < 0 or payroll > MaxPayrollPercent:
    raise newException(FirmError,
      "payroll must be 0.." & $MaxPayrollPercent & ": " & $payroll)
  if orders.len != Machines:
    raise newException(FirmError, "orders must name all " & $Machines &
      " machines")
  if split.len != Machines:
    raise newException(FirmError, "split must have " & $Machines & " shares")
  var shares: seq[float]
  for share in split:
    if share < 0:
      raise newException(FirmError, "a share cannot be negative: " & $share)
    shares.add(share.float)
  for worker in 0 ..< Machines:
    let line = normalizeLine(orders[worker])
    if line.len == 0:
      raise newException(FirmError, "unknown line: " & orders[worker])
    sim.nextOrders[worker] = line
  sim.nextPayroll = payroll
  var total = 0
  for share in split:
    total += share
  sim.nextSplit =
    if total == 100:
      [split[0], split[1], split[2], split[3]]
    else:
      normalizeSplit(shares)
  let memo = trimText(directive, MaxDirectiveLen)
  if memo.len > 0:
    sim.directive = memo
  if notes.len > 0:
    sim.notes[seat] = notes
  sim.memoDone = true
  sim.scriptedSeat[seat] = scripted
  var event = blankEvent(evMemo)
  event.shift = sim.shift
  event.seat = seat
  event.payroll = payroll
  for worker in 0 ..< Machines:
    event.orders.add(sim.nextOrders[worker])
    event.split.add(sim.nextSplit[worker])
  event.say = memo
  event.text = sim.notes[seat]
  event.scripted = scripted
  sim.addEvent(event)
  sim.maybeResolve()

proc applyWork*(sim: var Sim, seat: int, line: string, run, maint: int,
    report, notes: string, scripted: bool) =
  ## A worker spends its ten-hour shift. Raises FirmError on anything
  ## illegal; the game server falls back to the scripted baseline on a
  ## rejection. The last of the five decisions resolves the shift.
  if sim.done:
    raise newException(FirmError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(FirmError, "bad seat: " & $seat)
  if sim.isManager(seat):
    raise newException(FirmError, sim.names[seat] & " runs no machine")
  let worker = sim.workerIndex[seat]
  if sim.lines[worker].len > 0:
    raise newException(FirmError,
      sim.names[seat] & " has already worked this shift")
  let chosen = normalizeLine(line)
  if chosen.len == 0:
    raise newException(FirmError, "unknown line: " & line)
  if run < 0 or run > ShiftHours:
    raise newException(FirmError, "run must be 0.." & $ShiftHours & ": " & $run)
  if maint < 0 or maint > ShiftHours:
    raise newException(FirmError,
      "maint must be 0.." & $ShiftHours & ": " & $maint)
  if run + maint > ShiftHours:
    raise newException(FirmError,
      "a shift is " & $ShiftHours & " hours: " & $run & " + " & $maint)
  var message = trimText(report, MaxReportLen)
  if not sim.config.reports:
    message = ""
  sim.lines[worker] = chosen
  sim.runs[worker] = run
  sim.maints[worker] = maint
  sim.reports[worker] = message
  if notes.len > 0:
    sim.notes[seat] = notes
  sim.scriptedSeat[seat] = scripted
  var event = blankEvent(evWork)
  event.shift = sim.shift
  event.seat = seat
  event.worker = worker
  event.line = chosen
  event.run = run
  event.maint = maint
  event.say = message
  event.text = sim.notes[seat]
  event.scripted = scripted
  sim.addEvent(event)
  sim.maybeResolve()

proc endEarly*(sim: var Sim) =
  ## Stop now, between shifts. The hosted platform kills an episode that
  ## outlives its timeout and keeps NOTHING, so a short honest episode
  ## always beats a long one that never lands. Scores use the shifts
  ## actually played.
  if sim.done:
    return
  sim.settle("deadline")

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var roles = newJArray()
  var pay = newJArray()
  var units = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%sim.score(seat))
    roles.add(%sim.roleName(seat))
    if sim.isManager(seat):
      pay.add(%0.0)
      units.add(%0)
    else:
      pay.add(%sim.workerNet[sim.workerIndex[seat]])
      units.add(%sim.workerUnits[sim.workerIndex[seat]])
  %*{
    "names": names,
    "scores": scores,
    "roles": roles,
    "pay": pay,
    "units": units,
    "revenue": sim.firmRevenue,
    "wages": sim.firmWages,
    "profit": sim.firmProfit,
    "shifts": sim.shiftsPlayed,
    "maxShifts": sim.config.shifts,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc machineJson*(machine: MachineState): JsonNode =
  %*{
    "setup": machine.setup,
    "order": machine.order,
    "condition": machine.condition,
    "run": machine.run,
    "maint": machine.maint,
    "units": machine.units,
    "pay": machine.pay,
    "toil": machine.toil
  }

proc machineFromJson*(node: JsonNode): MachineState =
  MachineState(
    setup: node{"setup"}.getStr("A"),
    order: node{"order"}.getStr("A"),
    condition: node{"condition"}.getInt(),
    run: node{"run"}.getInt(),
    maint: node{"maint"}.getInt(),
    units: node{"units"}.getInt(),
    pay: node{"pay"}.getFloat(),
    toil: node{"toil"}.getFloat()
  )

proc tableStateJson*(sim: Sim): JsonNode =
  ## The SPECTATOR projection: it carries the order board AND every
  ## machine's condition, because the replay is where the audience gets to
  ## see both halves of the asymmetry at once. Players get the redacted
  ## `playerStateJson` instead.
  let pending = sim.pendingSeats()
  var seats = newJArray()
  for seat in 0 ..< Seats:
    var node: JsonNode
    if sim.isManager(seat):
      node = %*{
        "name": sim.names[seat], "role": "Manager", "roleId": 0, "worker": -1,
        "score": sim.score(seat), "share": 0, "pay": 0.0, "units": 0,
        "line": "", "order": "", "condition": -1, "run": -1, "maint": -1,
        "toil": 0.0, "say": sim.directive, "net": 0.0, "obeyed": true,
        "idle": false
      }
    else:
      let worker = sim.workerIndex[seat]
      let machine = sim.machines[worker]
      node = %*{
        "name": sim.names[seat], "role": "Worker", "roleId": 1,
        "worker": worker, "score": sim.score(seat),
        "share": sim.split[worker], "pay": machine.pay, "units": machine.units,
        "line": machine.setup, "order": machine.order,
        "condition": machine.condition, "run": machine.run,
        "maint": machine.maint, "toil": machine.toil,
        "say": sim.reports[worker],
        "net": sim.workerNet[worker],
        "obeyed": machine.setup == machine.order,
        "idle": machine.run == 0
      }
    node["notes"] = %sim.notes[seat]
    node["pending"] = %(seat in pending)
    node["scripted"] = %sim.scriptedSeat[seat]
    seats.add(node)
  var workerSeat = newJArray()
  var machines = newJArray()
  for worker in 0 ..< Machines:
    workerSeat.add(%sim.workerSeat[worker])
    let machine = sim.machines[worker]
    machines.add(%*{
      "machine": worker + 1,
      "seat": sim.workerSeat[worker],
      "name": sim.names[sim.workerSeat[worker]],
      "setup": machine.setup,
      "order": machine.order,
      "condition": machine.condition,
      "run": machine.run,
      "maint": machine.maint,
      "units": machine.units,
      "pay": machine.pay,
      "toil": machine.toil,
      "share": sim.split[worker],
      "obeyed": machine.setup == machine.order,
      "idle": machine.run == 0
    })
  let shown = min(sim.shift, sim.demandA.high)
  let ahead = min(sim.shift + 1, sim.demandA.high)
  var demandA = newJArray()
  var demandB = newJArray()
  for shift in 0 ..< sim.board.len:
    demandA.add(%sim.board[shift].a)
    demandB.add(%sim.board[shift].b)
  var madeA = newJArray()
  var madeB = newJArray()
  var profitSeries = newJArray()
  for record in sim.history:
    madeA.add(%(record.soldA + record.surplusA))
    madeB.add(%(record.soldB + record.surplusB))
    profitSeries.add(%record.profit)
  var paySeries = newJArray()
  var conditionSeries = newJArray()
  for worker in 0 ..< Machines:
    var pays = newJArray()
    var conditions = newJArray()
    for record in sim.history:
      pays.add(%record.pay[worker])
      conditions.add(%record.condition[worker])
    paySeries.add(pays)
    conditionSeries.add(conditions)
  var split = newJArray()
  for worker in 0 ..< Machines:
    split.add(%sim.split[worker])
  let last = if sim.history.len > 0: sim.history[^1] else: ShiftResult()
  %*{
    "seats": seats,
    "managerSeat": sim.managerSeat,
    "workerSeat": workerSeat,
    "machines": machines,
    "board": {
      "shift": sim.shift,
      "demandA": sim.demandA[shown],
      "demandB": sim.demandB[shown],
      "nextA": sim.demandA[ahead],
      "nextB": sim.demandB[ahead],
      "price": Price,
      "salvage": SalvagePrice,
      "switched": sim.shift >= sim.switchShift
    },
    "directive": sim.directive,
    "payroll": sim.payroll,
    "split": split,
    "ledger": {
      "revenue": last.revenue,
      "pool": last.pool,
      "profit": last.profit,
      "revenueTotal": sim.firmRevenue,
      "wagesTotal": sim.firmWages,
      "profitTotal": sim.firmProfit
    },
    "series": {
      "demandA": demandA,
      "demandB": demandB,
      "madeA": madeA,
      "madeB": madeB,
      "profit": profitSeries,
      "pay": paySeries,
      "condition": conditionSeries
    },
    "switchShift": sim.switchShift,
    "shift": sim.shift,
    "shifts": sim.config.shifts,
    "shiftsPlayed": sim.shiftsPlayed,
    "phase": $sim.phase,
    "gameDone": sim.done,
    "reason": sim.reason
  }

proc playerStateJson*(sim: Sim, seat: int): JsonNode =
  ## The REDACTED per-seat view. The manager sees the market and never a
  ## machine; a worker sees its machine and never the market. Decisions are
  ## server-side, so redaction loses nothing.
  let shown = min(sim.shift, sim.demandA.high)
  let ahead = min(sim.shift + 1, sim.demandA.high)
  if sim.isManager(seat):
    var floor = newJArray()
    var reports = newJArray()
    for worker in 0 ..< Machines:
      let machine = sim.machines[worker]
      floor.add(%*{
        "machine": worker + 1,
        "name": sim.names[sim.workerSeat[worker]],
        "setup": machine.setup,
        "order": machine.order,
        "units": machine.units,
        "pay": machine.pay,
        "share": sim.split[worker]
      })
      if sim.config.reports and sim.heardReports[worker].len > 0:
        reports.add(%*{
          "machine": worker + 1,
          "name": sim.names[sim.workerSeat[worker]],
          "say": sim.heardReports[worker]
        })
    var split = newJArray()
    for worker in 0 ..< Machines:
      split.add(%sim.split[worker])
    let last = if sim.history.len > 0: sim.history[^1] else: ShiftResult()
    result = %*{
      "name": sim.names[seat],
      "role": "Manager",
      "board": {
        "demandA": sim.demandA[shown],
        "demandB": sim.demandB[shown],
        "nextA": sim.demandA[ahead],
        "nextB": sim.demandB[ahead],
        "price": Price,
        "salvage": SalvagePrice
      },
      "floor": floor,
      "ledger": {
        "revenue": last.revenue,
        "pool": last.pool,
        "profit": last.profit,
        "revenueTotal": sim.firmRevenue,
        "wagesTotal": sim.firmWages,
        "profitTotal": sim.firmProfit
      },
      "payroll": sim.payroll,
      "split": split,
      "reports": reports,
      "directive": sim.directive,
      "notes": sim.notes[seat],
      "shift": sim.shift,
      "shifts": sim.config.shifts,
      "shiftsPlayed": sim.shiftsPlayed,
      "done": sim.done,
      "reason": sim.reason
    }
  else:
    let worker = sim.workerIndex[seat]
    let machine = sim.machines[worker]
    var floor = newJArray()
    for other in 0 ..< Machines:
      floor.add(%*{
        "machine": other + 1,
        "name": sim.names[sim.workerSeat[other]],
        "setup": sim.machines[other].setup,
        "order": sim.machines[other].order,
        "units": sim.machines[other].units
      })
    var split = newJArray()
    for other in 0 ..< Machines:
      split.add(%sim.split[other])
    result = %*{
      "name": sim.names[seat],
      "role": "Worker",
      "machine": worker + 1,
      "own": {
        "setup": machine.setup,
        "order": machine.order,
        "condition": machine.condition,
        "run": machine.run,
        "maint": machine.maint,
        "units": machine.units,
        "pay": machine.pay,
        "toil": machine.toil,
        "net": sim.workerNet[worker]
      },
      "directive": sim.directive,
      "payroll": sim.payroll,
      "split": split,
      "floor": floor,
      "notes": sim.notes[seat],
      "shift": sim.shift,
      "shifts": sim.config.shifts,
      "shiftsPlayed": sim.shiftsPlayed,
      "done": sim.done,
      "reason": sim.reason
    }

# ---- Replay -----------------------------------------------------------------

proc sameMachines(recorded: seq[MachineState],
    derived: array[Machines, MachineState]): bool =
  if recorded.len != Machines:
    return false
  for index in 0 ..< Machines:
    if recorded[index].setup != derived[index].setup or
        recorded[index].order != derived[index].order or
        recorded[index].condition != derived[index].condition or
        recorded[index].run != derived[index].run or
        recorded[index].maint != derived[index].maint or
        recorded[index].units != derived[index].units:
      return false
  true

proc moneyClose(a, b: float): bool =
  abs(a - b) <= 1e-6

proc checkShift(event: GameEvent, sim: Sim) =
  var split: seq[int]
  for worker in 0 ..< Machines:
    split.add(sim.split[worker])
  if event.shift != sim.shift or event.demandA != sim.demandA[sim.shift] or
      event.demandB != sim.demandB[sim.shift] or
      event.payroll != sim.payroll or event.split != split or
      event.text != sim.directive or
      not sameMachines(event.machines, sim.machines):
    raise newException(FirmError,
      "shift " & $event.shift & " does not match the seeded re-derivation")

proc checkSettle(event: GameEvent, record: ShiftResult) =
  var units, condition: seq[int]
  var pay, toil: seq[float]
  var obeyed, idle: seq[bool]
  for worker in 0 ..< Machines:
    units.add(record.units[worker])
    condition.add(record.condition[worker])
    pay.add(record.pay[worker])
    toil.add(record.toil[worker])
    obeyed.add(record.obeyed[worker])
    idle.add(record.idle[worker])
  var moneyOk = moneyClose(event.revenue, record.revenue) and
    moneyClose(event.pool, record.pool) and
    moneyClose(event.profit, record.profit)
  if moneyOk and event.pay.len == Machines and event.toil.len == Machines:
    for worker in 0 ..< Machines:
      if not moneyClose(event.pay[worker], pay[worker]) or
          not moneyClose(event.toil[worker], toil[worker]):
        moneyOk = false
  else:
    moneyOk = false
  if event.shift != record.shift or event.units != units or
      event.condition != condition or event.soldA != record.soldA or
      event.soldB != record.soldB or event.surplusA != record.surplusA or
      event.surplusB != record.surplusB or event.obeyed != obeyed or
      event.idle != idle or not moneyOk:
    raise newException(FirmError,
      "settlement of shift " & $event.shift &
      " does not match the seeded re-derivation")

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying
  ## the memo and work events through the rules (roles, the demand levels
  ## and the switch shift come from the seed). frames[i] = state after
  ## events[0..<i]; `shift` and `settle` events are DERIVED and only
  ## checked, so a tampered recording raises.
  var sim = initSim(config)
  ## initSim already logged the start and the first shift event; the
  ## recorded log opens with those same two.
  sim.events = @[]
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evShift:
      checkShift(event, sim)
      if sim.events.len == 0 or sim.events[^1].kind != evShift:
        sim.events.add(event)
    of evMemo:
      sim.applyMemo(event.seat, event.orders, event.payroll, event.split,
        event.say, event.text, event.scripted)
    of evWork:
      sim.applyWork(event.seat, event.line, event.run, event.maint,
        event.say, event.text, event.scripted)
    of evSettle:
      if sim.history.len == 0:
        raise newException(FirmError, "a settlement with no resolved shift")
      checkSettle(event, sim.history[^1])
    of evEnd:
      if not sim.done:
        ## A deadline stop is not derivable from the decisions alone.
        sim.settle(event.text)
    result.add(sim)

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.shift >= 0:
    result["shift"] = %event.shift
  case event.kind
  of evStart:
    discard
  of evShift:
    result["demandA"] = %event.demandA
    result["demandB"] = %event.demandB
    result["payroll"] = %event.payroll
    result["split"] = %event.split
    var machines = newJArray()
    for machine in event.machines:
      machines.add(machineJson(machine))
    result["machines"] = machines
  of evMemo:
    result["seat"] = %event.seat
    result["orders"] = %event.orders
    result["payroll"] = %event.payroll
    result["split"] = %event.split
    result["scripted"] = %event.scripted
    if event.say.len > 0:
      result["say"] = %event.say
  of evWork:
    result["seat"] = %event.seat
    result["worker"] = %event.worker
    result["line"] = %event.line
    result["run"] = %event.run
    result["maint"] = %event.maint
    result["scripted"] = %event.scripted
    if event.say.len > 0:
      result["say"] = %event.say
  of evSettle:
    result["units"] = %event.units
    result["condition"] = %event.condition
    result["soldA"] = %event.soldA
    result["soldB"] = %event.soldB
    result["surplusA"] = %event.surplusA
    result["surplusB"] = %event.surplusB
    result["revenue"] = %event.revenue
    result["pool"] = %event.pool
    result["profit"] = %event.profit
    result["pay"] = %event.pay
    result["toil"] = %event.toil
    result["obeyed"] = %event.obeyed
    result["idle"] = %event.idle
  of evEnd:
    discard
  if event.text.len > 0:
    result["text"] = %event.text

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    shift: node{"shift"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    worker: node{"worker"}.getInt(-1),
    line: node{"line"}.getStr(""),
    run: node{"run"}.getInt(-1),
    maint: node{"maint"}.getInt(-1),
    say: node{"say"}.getStr(""),
    text: node{"text"}.getStr(""),
    scripted: node{"scripted"}.getBool(false),
    demandA: node{"demandA"}.getInt(-1),
    demandB: node{"demandB"}.getInt(-1),
    payroll: node{"payroll"}.getInt(-1),
    soldA: node{"soldA"}.getInt(-1),
    soldB: node{"soldB"}.getInt(-1),
    surplusA: node{"surplusA"}.getInt(-1),
    surplusB: node{"surplusB"}.getInt(-1),
    revenue: node{"revenue"}.getFloat(),
    pool: node{"pool"}.getFloat(),
    profit: node{"profit"}.getFloat()
  )
  if node.hasKey("machines"):
    for machine in node["machines"]:
      result.machines.add(machineFromJson(machine))
  if node.hasKey("orders"):
    for order in node["orders"]:
      result.orders.add(order.getStr())
  if node.hasKey("split"):
    for share in node["split"]:
      result.split.add(share.getInt())
  if node.hasKey("units"):
    for value in node["units"]:
      result.units.add(value.getInt())
  if node.hasKey("condition"):
    for value in node["condition"]:
      result.condition.add(value.getInt())
  if node.hasKey("pay"):
    for value in node["pay"]:
      result.pay.add(value.getFloat())
  if node.hasKey("toil"):
    for value in node["toil"]:
      result.toil.add(value.getFloat())
  if node.hasKey("obeyed"):
    for value in node["obeyed"]:
      result.obeyed.add(value.getBool())
  if node.hasKey("idle"):
    for value in node["idle"]:
      result.idle.add(value.getBool())
