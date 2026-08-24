## The scripted baselines must play whole episodes without ever proposing an
## illegal move — they are both the no-credentials fallback (offline
## certification) and fieldable policies, so this is the completion path.
## Both are role-complete: a policy does not know which role the seed will
## deal it.

import std/[json, monotimes, strutils, times, unicode, unittest]
import firm/[llm, sim]

proc fixture(seed: int, shifts = 8, reports = true): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.shifts = shifts
  result.reports = reports
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc apply(sim: var Sim, seat: int, decision: Decision) =
  ## The bot's move must be legal as-is: applyMemo / applyWork raise on
  ## anything else and would fail these tests.
  if sim.isManager(seat):
    check decision.payroll in 0 .. MaxPayrollPercent
    check decision.split.len == Machines
    var total = 0
    for share in decision.split:
      check share >= 0
      total += share
    check total == 100
    check decision.orders.len == Machines
    for line in decision.orders:
      check line == "A" or line == "B"
    check decision.say.runeLen <= MaxDirectiveLen
    sim.applyMemo(seat, decision.orders, decision.payroll, decision.split,
      decision.say, decision.notes, true)
  else:
    check decision.line == "A" or decision.line == "B"
    check decision.run in 0 .. ShiftHours
    check decision.maint in 0 .. ShiftHours
    check decision.run + decision.maint <= ShiftHours
    check decision.say.runeLen <= MaxReportLen
    sim.applyWork(seat, decision.line, decision.run, decision.maint,
      decision.say, decision.notes, true)
  check decision.notes.len == 0

proc playScripted(config: GameConfig,
    kinds: array[Seats, ScriptKind]): Sim =
  result = initSim(config)
  while not result.done:
    for seat in result.orderedSeats():
      result.apply(seat, scriptedAction(result, seat, kinds[seat]))

const
  AllSteady = [skSteady, skSteady, skSteady, skSteady, skSteady]
  AllTaskmaster = [skTaskmaster, skTaskmaster, skTaskmaster, skTaskmaster,
    skTaskmaster]
  Mixed = [skSteady, skTaskmaster, skSteady, skTaskmaster, skSteady]

suite "scripted baselines":
  test "every baseline in every role plays a legal, bounded, fast episode":
    for seed in [1, 7, 42, 1234]:
      for kinds in [AllSteady, AllTaskmaster, Mixed]:
        let started = getMonoTime()
        let sim = playScripted(fixture(seed), kinds)
        let elapsed = (getMonoTime() - started).inMilliseconds
        check sim.done
        check sim.reason == "complete"
        check sim.shiftsPlayed == sim.config.shifts
        var memos = 0
        var works = 0
        for event in sim.events:
          case event.kind
          of evMemo:
            inc memos
            check event.payroll in 0 .. MaxPayrollPercent
            check event.say.runeLen <= MaxDirectiveLen
          of evWork:
            inc works
            check event.run in 0 .. ShiftHours
            check event.maint in 0 .. ShiftHours
            check event.run + event.maint <= ShiftHours
            check event.say.runeLen <= MaxReportLen
          else: discard
        check memos == sim.config.shifts
        check works == sim.config.shifts * Machines
        check elapsed < 2000

  test "steady holds the machines; taskmaster destroys them":
    for seed in [1, 7, 42, 1234]:
      let steady = playScripted(fixture(seed), AllSteady)
      for worker in 0 ..< Machines:
        check abs(steady.machines[worker].condition - MaxCondition) <= 3
      ## The competent baseline always runs the line it was ordered on.
      var disobeyed = 0
      for record in steady.history:
        for worker in 0 ..< Machines:
          if not record.obeyed[worker]:
            inc disobeyed
      check disobeyed == 0

      var wrecked = false
      let taskmaster = playScripted(fixture(seed, shifts = 4), AllTaskmaster)
      for worker in 0 ..< Machines:
        if taskmaster.machines[worker].condition < 25:
          wrecked = true
      check wrecked

  test "the competent baseline is the one a prompt has to beat":
    ## NOTE (deviation from the design note, reported in phase 20): the note
    ## asserted the all-steady MANAGER outscores the all-taskmaster manager.
    ## It does not, and cannot: taskmaster's workers obey at run 10 whatever
    ## they are paid, so its 20% pay rule simply keeps more revenue than
    ## steady's 40%. The true statement — and the one that carries the same
    ## meaning — is that steady's floor is worth strictly more in total, and
    ## its workers are worth vastly more to themselves. Both managers' scores
    ## are echoed so tuning drift stays visible.
    for seed in [1, 7, 42, 1234]:
      let steady = playScripted(fixture(seed), AllSteady)
      let taskmaster = playScripted(fixture(seed), AllTaskmaster)
      var steadySurplus = steady.firmProfit
      var taskSurplus = taskmaster.firmProfit
      for worker in 0 ..< Machines:
        steadySurplus += steady.workerNet[worker]
        taskSurplus += taskmaster.workerNet[worker]
        check steady.score(steady.workerSeat[worker]) >
          taskmaster.score(taskmaster.workerSeat[worker])
      echo "seed ", seed,
        ": steady manager ", steady.score(steady.managerSeat).formatFloat(
          ffDecimal, 3),
        " workers ", steady.score(steady.workerSeat[0]).formatFloat(
          ffDecimal, 3),
        " surplus ", steadySurplus.formatFloat(ffDecimal, 1),
        " | taskmaster manager ", taskmaster.score(
          taskmaster.managerSeat).formatFloat(ffDecimal, 3),
        " workers ", taskmaster.score(taskmaster.workerSeat[0]).formatFloat(
          ffDecimal, 3),
        " surplus ", taskSurplus.formatFloat(ffDecimal, 1)
      check steadySurplus > taskSurplus

  test "the steady baseline never lies in its reports":
    var sim = initSim(fixture(5, shifts = 6))
    while not sim.done:
      for seat in sim.orderedSeats():
        let decision = scriptedAction(sim, seat, skSteady)
        if not sim.isManager(seat):
          let worker = sim.workerIndex[seat]
          let machine = sim.machines[worker]
          check decision.say == machineLabel(worker) & ": condition " &
            $machine.condition & ", ran " & $machine.run & ", maintained " &
            $machine.maint & ", " & $machine.units & " units."
        sim.apply(seat, decision)

  test "a scripted move carries its own provenance; a parsed reply does not":
    ## The seat's static registration cannot tell you that an LLM seat fell
    ## back mid-episode, and phase 60 counts fallbacks from the replay — so
    ## the flag rides on the decision.
    let sim = initSim(fixture(9))
    check scriptedAction(sim, sim.managerSeat, skSteady).scripted
    check scriptedAction(sim, sim.workerSeat[0], skTaskmaster).scripted
    check not parseManagerReply(sim, parseJson(
      """{"payroll": 30}""")).scripted
    check not parseWorkerReply(sim, sim.workerSeat[0], parseJson(
      """{"run": 5}""")).scripted

  test "with no credentials every seat plays scripted, with no network call":
    let config = fixture(3, shifts = 6)
    let client = newLlmClient(config)
    check client.disabled
    var sim = initSim(config)
    let seats = sim.orderedSeats()
    check seats.len == Seats
    var prompts = newSeq[string](Seats)
    prompts[seats[0]] = "be bold"
    var scripted = newSeq[ScriptKind](Seats)
    scripted[sim.workerSeat[1]] = skTaskmaster
    let started = getMonoTime()
    let decisions = client.decideAll(sim, seats, prompts, scripted)
    check (getMonoTime() - started).inMilliseconds < 500
    check decisions.len == Seats
    for index, seat in seats:
      let kind = if seat == sim.workerSeat[1]: skTaskmaster else: skSteady
      let expected = scriptedAction(sim, seat, kind)
      check decisions[index].line == expected.line
      check decisions[index].run == expected.run
      check decisions[index].payroll == expected.payroll
      check decisions[index].scripted
      sim.apply(seat, decisions[index])
    check sim.shift == 1

suite "reply parsing":
  test "the manager's reply is tolerant on orders, strict on the pay rule":
    let sim = initSim(fixture(11))
    let full = parseManagerReply(sim, parseJson("""
      {"orders": ["b", "Line A", "A", "B"], "payroll": 45,
       "split": [30, 30, 20, 20], "directive": "switch 1 to B",
       "notes": "watching machine 4"}"""))
    check full.orders == @["B", "A", "A", "B"]
    check full.payroll == 45
    check full.split == @[30, 30, 20, 20]
    check full.say == "switch 1 to B"
    check full.notes == "watching machine 4"
    ## A float payroll rounds; a numeric string parses.
    check parseManagerReply(sim, parseJson(
      """{"payroll": 39.6}""")).payroll == 40
    check parseManagerReply(sim, parseJson(
      """{"payroll": " 20 "}""")).payroll == 20
    ## An unknown line, a short array or a missing key keeps the machine's
    ## current order — never invalid.
    check parseManagerReply(sim, parseJson(
      """{"orders": ["Z","Z","Z","Z"], "payroll": 30}""")).orders ==
      @["A", "A", "A", "B"]
    check parseManagerReply(sim, parseJson(
      """{"orders": ["B"], "payroll": 30}""")).orders == @["A", "A", "A", "B"]
    check parseManagerReply(sim, parseJson(
      """{"payroll": 30}""")).orders == @["A", "A", "A", "B"]
    ## A split that does not sum to 100 is renormalized; all-zero is equal.
    check parseManagerReply(sim, parseJson(
      """{"payroll": 30, "split": [2, 2, 2, 2]}""")).split ==
      @[25, 25, 25, 25]
    check parseManagerReply(sim, parseJson(
      """{"payroll": 30, "split": [0, 0, 0, 0]}""")).split ==
      @[25, 25, 25, 25]
    check parseManagerReply(sim, parseJson(
      """{"payroll": 30}""")).split == @[25, 25, 25, 25]
    ## Missing, non-numeric or out-of-range payroll is invalid.
    expect FirmError:
      discard parseManagerReply(sim, parseJson("""{"split": [1,1,1,1]}"""))
    expect FirmError:
      discard parseManagerReply(sim, parseJson("""{"payroll": "lots"}"""))
    expect FirmError:
      discard parseManagerReply(sim, parseJson("""{"payroll": -1}"""))
    expect FirmError:
      discard parseManagerReply(sim, parseJson("""{"payroll": 61}"""))
    ## A split that is present but malformed is invalid.
    expect FirmError:
      discard parseManagerReply(sim, parseJson(
        """{"payroll": 30, "split": [50, 50]}"""))
    expect FirmError:
      discard parseManagerReply(sim, parseJson(
        """{"payroll": 30, "split": [-1, 40, 30, 31]}"""))

  test "a worker's reply is tolerant on the line, strict on the hours":
    let sim = initSim(fixture(11))
    let seat = sim.workerSeat[0]
    let full = parseWorkerReply(sim, seat, parseJson("""
      {"line": "line b", "run": 7, "maint": 3, "report": "needs a bearing",
       "notes": "condition 84"}"""))
    check full.line == "B"
    check full.run == 7
    check full.maint == 3
    check full.say == "needs a bearing"
    check full.notes == "condition 84"
    check parseWorkerReply(sim, seat, parseJson(
      """{"run": 6.4}""")).run == 6
    check parseWorkerReply(sim, seat, parseJson(
      """{"run": "8"}""")).run == 8
    ## An unknown or missing line keeps the machine where it is.
    check parseWorkerReply(sim, seat, parseJson(
      """{"line": "C", "run": 5}""")).line == sim.machines[0].setup
    check parseWorkerReply(sim, seat, parseJson(
      """{"run": 5}""")).line == sim.machines[0].setup
    ## Missing maint is zero.
    check parseWorkerReply(sim, seat, parseJson("""{"run": 5}""")).maint == 0
    expect FirmError:
      discard parseWorkerReply(sim, seat, parseJson("""{"maint": 3}"""))
    expect FirmError:
      discard parseWorkerReply(sim, seat, parseJson("""{"run": -1}"""))
    expect FirmError:
      discard parseWorkerReply(sim, seat, parseJson("""{"run": 11}"""))
    expect FirmError:
      discard parseWorkerReply(sim, seat, parseJson(
        """{"run": 3, "maint": 11}"""))
    expect FirmError:
      discard parseWorkerReply(sim, seat, parseJson(
        """{"run": 6, "maint": 5}"""))

  test "free text is capped on rune boundaries":
    let sim = initSim(fixture(11))
    let seat = sim.workerSeat[0]
    var long = ""
    for index in 0 ..< 700:
      long.add("é")
    check cleanText(long, MaxNotesLen).runeLen == MaxNotesLen
    check cleanText(long, MaxDirectiveLen).runeLen == MaxDirectiveLen
    check cleanText(long, MaxReportLen).runeLen == MaxReportLen
    check cleanText(long, MaxNotesLen).validateUtf8() == -1
    let manager = parseManagerReply(sim, %*{
      "payroll": 40, "directive": long, "notes": long})
    check manager.say.runeLen == MaxDirectiveLen
    check manager.notes.runeLen == MaxNotesLen
    let worker = parseWorkerReply(sim, seat, %*{
      "run": 6, "maint": 3, "report": long, "notes": long})
    check worker.say.runeLen == MaxReportLen
    check worker.notes.runeLen == MaxNotesLen
    check parseScriptKind("1") == skSteady
    check parseScriptKind("steady") == skSteady
    check parseScriptKind("taskmaster") == skTaskmaster
    check parseScriptKind("") == skNone

  test "a reply with no JSON is quoted back on rune boundaries":
    ## The quoted head goes to the container log, which phase 60 reads; a
    ## byte slice through a multi-byte character makes it unreadable.
    var long = ""
    for index in 0 ..< 400:
      long.add("é")
    expect FirmError:
      discard extractJsonObject(long)
    try:
      discard extractJsonObject(long)
    except FirmError as error:
      check error.msg.validateUtf8() == -1
      check error.msg.runeLen < long.runeLen

  test "prompts carry the seat's own view and nothing hidden":
    var sim = initSim(fixture(7, shifts = 8, reports = false))
    for seat in sim.orderedSeats():
      sim.apply(seat, scriptedAction(sim, seat, skSteady))
    let manager = sim.userPrompt(sim.managerSeat, "operator says hi")
    check "THE BOARD" in manager
    check "THE FLOOR" in manager
    check "operator says hi" in manager
    ## With the report channel closed the manager's own view carries no
    ## machine internals at all: no condition, no hours, no effort.
    check "condition" notin manager.toLowerAscii()
    check "maintain" notin manager.toLowerAscii()
    check "effort" notin manager.toLowerAscii()

    let worker = sim.userPrompt(sim.workerSeat[1], "run it hot")
    check "YOUR MACHINE" in worker
    check "MACHINE 2" in worker
    check "run it hot" in worker
    ## The order board is the manager's alone: no demand numbers, no prices,
    ## no firm ledger. ("revenue" appears only as the word in the pay rule —
    ## the percentage is public, the amount is not.)
    for word in ["THE BOARD", "wants", "scrap", "salvage", "$10", "HISTORY:\nshift | A wanted"]:
      check word notin worker
    check "THE FLOOR:" notin worker
