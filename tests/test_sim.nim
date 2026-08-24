import std/[json, math, random, sets, strutils, unicode, unittest]
import firm/sim

proc fixtureConfig(shifts = 8, seed = 0, reports = true): GameConfig =
  result = defaultGameConfig()
  result.shifts = shifts
  result.seed = seed
  result.reports = reports
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc flatBoard(sim: var Sim, wantA, wantB: int) =
  ## Pin the order board so a shift can be computed by hand.
  for index in 0 .. sim.demandA.high:
    sim.demandA[index] = wantA
    sim.demandB[index] = wantB

proc memo(sim: var Sim, orders: seq[string], payroll: int, split: seq[int],
    directive = "", notes = "", scripted = true) =
  sim.applyMemo(sim.managerSeat, orders, payroll, split, directive, notes,
    scripted)

proc work(sim: var Sim, lines: array[Machines, string],
    runs, maints: array[Machines, int], report = "", scripted = true) =
  for worker in 0 ..< Machines:
    sim.applyWork(sim.workerSeat[worker], lines[worker], runs[worker],
      maints[worker], report, "", scripted)

proc currentSetups(sim: Sim): array[Machines, string] =
  for worker in 0 ..< Machines:
    result[worker] = sim.machines[worker].setup

proc orderedLines(sim: Sim): array[Machines, string] =
  for worker in 0 ..< Machines:
    result[worker] = sim.machines[worker].order

proc close(a, b: float): bool =
  abs(a - b) < 1e-9

suite "roles and the seeded draw":
  test "exactly one manager and four workers, mutually consistent":
    for seed in [0, 1, 7, 42, 1234]:
      let sim = initSim(fixtureConfig(seed = seed))
      var managers = 0
      for seat in 0 ..< Seats:
        if sim.roleOf[seat] == 0:
          inc managers
          check seat == sim.managerSeat
          check sim.workerIndex[seat] == -1
          check sim.roleName(seat) == "Manager"
        else:
          let worker = sim.workerIndex[seat]
          check worker in 0 ..< Machines
          check sim.workerSeat[worker] == seat
          check sim.roleName(seat) == "Worker"
      check managers == 1
      ## Worker seats are in ascending seat order.
      for worker in 1 ..< Machines:
        check sim.workerSeat[worker] > sim.workerSeat[worker - 1]
    var offices = initHashSet[int]()
    for seed in 0 ..< 20:
      offices.incl(initSim(fixtureConfig(seed = seed)).managerSeat)
    check offices.len > 1

  test "the order board is flat, switches once, and hides nothing else":
    for seed in [0, 1, 7, 42, 1234]:
      let sim = initSim(fixtureConfig(shifts = 8, seed = seed))
      check sim.demandA.len == sim.config.shifts + 2
      check sim.demandB.len == sim.config.shifts + 2
      check sim.switchShift in 3 .. 5
      let high = sim.demandA[0]
      let low = sim.demandB[0]
      check high in 30 .. 36
      check low in 12 .. 18
      for shift in 0 .. sim.demandA.high:
        if shift < sim.switchShift:
          check sim.demandA[shift] == high
          check sim.demandB[shift] == low
        else:
          check sim.demandA[shift] == low
          check sim.demandB[shift] == high
    var highs = initHashSet[int]()
    var lows = initHashSet[int]()
    for seed in 0 ..< 200:
      let sim = initSim(fixtureConfig(seed = seed))
      highs.incl(sim.demandA[0])
      lows.incl(sim.demandB[0])
    check highs.len > 1
    check lows.len > 1

  test "the floor opens with four fresh machines and the standing order":
    let sim = initSim(fixtureConfig())
    check sim.shift == 0
    check sim.shiftsPlayed == 0
    check sim.phase == phShift
    check sim.payroll == InitialPayrollPercent
    check sim.split == [25, 25, 25, 25]
    check sim.directive == StandingOrder
    check sim.currentSetups() == ["A", "A", "A", "B"]
    check sim.orderedLines() == ["A", "A", "A", "B"]
    for worker in 0 ..< Machines:
      check sim.machines[worker].condition == MaxCondition
      check sim.machines[worker].run == 0
      check sim.machines[worker].maint == 0
      check sim.machines[worker].units == 0
    check sim.pendingSeats().len == Seats
    check sim.events.len == 2
    check sim.events[0].kind == evStart
    check sim.events[1].kind == evShift
    check sim.events[1].text == StandingOrder

  test "seed determinism":
    let a = initSim(fixtureConfig(seed = 77))
    let b = initSim(fixtureConfig(seed = 77))
    let c = initSim(fixtureConfig(seed = 78))
    check a.roleOf == b.roleOf
    check a.demandA == b.demandA
    check a.demandB == b.demandB
    check a.switchShift == b.switchShift
    check a.names == b.names
    check a.roleOf != c.roleOf or a.demandA != c.demandA or
      a.switchShift != c.switchShift or a.names != c.names

suite "resolution":
  test "hand-computed shift: 33 A / 15 B, run 6 maint 3, payroll 40":
    var sim = initSim(fixtureConfig(shifts = 8, seed = 5))
    sim.flatBoard(33, 15)
    ## Shift 0 runs on the opening pay rule (payroll 30); the memo filed now
    ## puts payroll 40 in force for shift 1.
    sim.memo(@["A", "A", "A", "B"], 40, @[25, 25, 25, 25])
    sim.work(sim.currentSetups(), [6, 6, 6, 6], [3, 3, 3, 3])
    let first = sim.history[0]
    for worker in 0 ..< Machines:
      check first.units[worker] == 12
      check first.condition[worker] == MaxCondition   ## -18 + 18
      check close(first.toil[worker], 13.5)
    check first.soldA == 33
    check first.surplusA == 3
    check first.soldB == 12
    check first.surplusB == 0
    check close(first.revenue, 456.0)
    check close(first.pool, 456.0 * 0.30)
    ## Shift 1: same floor, now at payroll 40 on an equal split.
    check sim.payroll == 40
    sim.memo(@["A", "A", "A", "B"], 40, @[25, 25, 25, 25])
    sim.work(sim.currentSetups(), [6, 6, 6, 6], [3, 3, 3, 3])
    let second = sim.history[1]
    check close(second.revenue, 456.0)
    check close(second.pool, 182.4)
    check close(second.profit, 273.6)
    for worker in 0 ..< Machines:
      check close(second.pay[worker], 45.6)

  test "changeover, wear, repair and the condition floor":
    var sim = initSim(fixtureConfig(shifts = 8, seed = 5))
    sim.flatBoard(40, 40)
    ## Machine 0 is set to A and runs B: two of its six hours go to the
    ## changeover, so 2 x (6 - 2) x 1.0 = 8 units, and it ends on B.
    sim.memo(@["A", "A", "A", "B"], 30, @[25, 25, 25, 25])
    sim.work(["B", "A", "A", "B"], [6, 10, 4, 0], [3, 0, 6, 0])
    check sim.history[0].units[0] == 8
    check sim.machines[0].setup == "B"
    check sim.machines[0].condition == MaxCondition   ## -12 +18, clamped
    check sim.machines[1].condition == 70                    ## run 10, maint 0
    check sim.machines[2].condition == 100                   ## +24, clamped
    check sim.history[0].units[3] == 0
    check sim.history[0].idle[3]
    ## Drive machine 1 into the floor and check q halves the output exactly.
    for shift in 1 .. 3:
      sim.memo(@["A", "A", "A", "B"], 30, @[25, 25, 25, 25])
      sim.work(sim.currentSetups(), [10, 10, 10, 10], [0, 0, 0, 0])
    check sim.machines[1].condition == 0
    let before = sim.machines[1].condition
    check before == 0
    sim.memo(@["A", "A", "A", "B"], 30, @[25, 25, 25, 25])
    sim.work(sim.currentSetups(), [6, 6, 6, 6], [3, 3, 3, 3])
    ## q = 0.5 at condition 0: 2.0 x 6 x 0.5 = 6, exactly half of 12.
    check sim.history[^1].units[1] == 6

  test "the memo binds nobody until the next shift":
    var sim = initSim(fixtureConfig(shifts = 6, seed = 11))
    sim.flatBoard(40, 40)
    let openingSplit = sim.split
    sim.memo(@["B", "B", "B", "A"], 55, @[70, 10, 10, 10], "switch everything")
    ## Still the opening rule while shift 0 resolves.
    check sim.payroll == InitialPayrollPercent
    check sim.split == openingSplit
    check sim.orderedLines() == ["A", "A", "A", "B"]
    ## The directive is cheap talk and is posted at once; the pay rule is
    ## the enforceable half and waits.
    check sim.directive == "switch everything"
    sim.work(sim.currentSetups(), [6, 6, 6, 6], [3, 3, 3, 3])
    check close(sim.history[0].pool,
      sim.history[0].revenue * InitialPayrollPercent.float / 100.0)
    check sim.payroll == 55
    check sim.split == [70, 10, 10, 10]
    check sim.orderedLines() == ["B", "B", "B", "A"]
    check sim.events[^1].kind == evShift
    check sim.events[^1].payroll == 55
    ## An empty directive leaves the standing one alone.
    sim.memo(@["B", "B", "B", "A"], 55, @[70, 10, 10, 10], "")
    check sim.directive == "switch everything"

suite "the pay rule":
  test "normalizeSplit always sums to exactly 100":
    check normalizeSplit(@[1.0, 1.0, 1.0, 1.0]) == [25, 25, 25, 25]
    check normalizeSplit(@[50.0, 50.0, 0.0, 0.0]) == [50, 50, 0, 0]
    check normalizeSplit(@[1.0, 0.0, 0.0, 0.0]) == [100, 0, 0, 0]
    check normalizeSplit(@[0.0, 0.0, 0.0, 0.0]) == [25, 25, 25, 25]
    check normalizeSplit(@[]) == [25, 25, 25, 25]
    let thirds = normalizeSplit(@[1.0, 1.0, 1.0, 0.0])
    var total = 0
    for share in thirds:
      check share >= 0
      total += share
    check total == 100
    var rng = initRand(20260823)
    for attempt in 0 ..< 500:
      var values: seq[float]
      for index in 0 ..< Machines:
        values.add(rng.rand(0.0 .. 40.0))
      let shares = normalizeSplit(values)
      var sum = 0
      for share in shares:
        check share >= 0
        sum += share
      check sum == 100

  test "illegal decisions raise and change nothing":
    var sim = initSim(fixtureConfig(shifts = 8, seed = 1))
    let pendingBefore = sim.pendingSeats()
    let manager = sim.managerSeat
    let hand = sim.workerSeat[0]
    expect FirmError:
      sim.applyWork(hand, "A", -1, 0, "", "", false)
    expect FirmError:
      sim.applyWork(hand, "A", 11, 0, "", "", false)
    expect FirmError:
      sim.applyWork(hand, "A", 0, 11, "", "", false)
    expect FirmError:
      sim.applyWork(hand, "A", 6, 5, "", "", false)
    expect FirmError:
      sim.applyWork(hand, "C", 6, 3, "", "", false)
    expect FirmError:
      sim.applyWork(manager, "A", 6, 3, "", "", false)
    expect FirmError:
      sim.applyMemo(manager, @["A", "A", "A", "B"], -1, @[25, 25, 25, 25],
        "", "", false)
    expect FirmError:
      sim.applyMemo(manager, @["A", "A", "A", "B"], 61, @[25, 25, 25, 25],
        "", "", false)
    expect FirmError:
      sim.applyMemo(manager, @["A", "A", "A", "B"], 40, @[50, 50], "", "",
        false)
    expect FirmError:
      sim.applyMemo(hand, @["A", "A", "A", "B"], 40, @[25, 25, 25, 25], "",
        "", false)
    check sim.pendingSeats() == pendingBefore
    sim.applyWork(hand, "A", 6, 3, "", "", false)
    expect FirmError:
      sim.applyWork(hand, "A", 6, 3, "", "", false)
    sim.memo(@["A", "A", "A", "B"], 40, @[25, 25, 25, 25])
    expect FirmError:
      sim.applyMemo(manager, @["A", "A", "A", "B"], 40, @[25, 25, 25, 25],
        "", "", false)
    check sim.shift == 0

  test "recorded text is cut on rune boundaries":
    var sim = initSim(fixtureConfig(shifts = 4, seed = 1))
    var long = ""
    for index in 0 ..< 400:
      long.add("é")
    sim.memo(@["A", "A", "A", "B"], 40, @[25, 25, 25, 25], long)
    check sim.directive.runeLen == MaxDirectiveLen
    check sim.directive.validateUtf8() == -1
    sim.work(sim.currentSetups(), [6, 6, 6, 6], [3, 3, 3, 3], report = long)
    for worker in 0 ..< Machines:
      check sim.heardReports[worker].runeLen == MaxReportLen
      check sim.heardReports[worker].validateUtf8() == -1
    for event in sim.events:
      check event.say.validateUtf8() == -1
      check event.text.validateUtf8() == -1
    var quiet = initSim(fixtureConfig(shifts = 4, seed = 1, reports = false))
    quiet.memo(@["A", "A", "A", "B"], 40, @[25, 25, 25, 25])
    quiet.work(quiet.currentSetups(), [6, 6, 6, 6], [3, 3, 3, 3],
      report = "machine is fine")
    for worker in 0 ..< Machines:
      check quiet.heardReports[worker] == ""

suite "the observation split":
  test "the manager never sees a machine; a worker never sees the market":
    var sim = initSim(fixtureConfig(shifts = 6, seed = 3, reports = false))
    for shift in 0 ..< 6:
      let manager = sim.playerStateJson(sim.managerSeat)
      let managerText = $manager
      for key in ["condition", "run", "maint", "toil"]:
        check ("\"" & key & "\"") notin managerText
      for worker in 0 ..< Machines:
        let seat = sim.workerSeat[worker]
        let text = $sim.playerStateJson(seat)
        for key in ["demandA", "demandB", "price", "salvage", "revenue",
            "profit", "wagesTotal"]:
          check ("\"" & key & "\"") notin text
      if sim.done:
        break
      sim.memo(@["A", "A", "A", "B"], 40, @[25, 25, 25, 25], "keep going")
      sim.work(sim.currentSetups(), [6, 6, 6, 6], [3, 3, 3, 3])
    check sim.done

suite "scoring and endings":
  test "the two formulas, their sign, and the results payload":
    var sim = initSim(fixtureConfig(shifts = 6, seed = 9))
    sim.flatBoard(33, 15)
    ## Machine 0 works for a share that the manager cuts to nothing.
    sim.memo(@["A", "A", "A", "B"], 40, @[0, 34, 33, 33])
    sim.work(sim.currentSetups(), [6, 0, 0, 0], [3, 0, 0, 0])
    while not sim.done:
      sim.memo(@["A", "A", "A", "B"], 40, @[0, 34, 33, 33])
      sim.work(sim.currentSetups(), [6, 0, 0, 0], [3, 0, 0, 0])
    check sim.reason == "complete"
    let shifts = sim.shiftsPlayed.float
    for seat in 0 ..< Seats:
      if sim.isManager(seat):
        check close(sim.score(seat),
          sim.firmProfit / (shifts * ManagerScoreScale))
      else:
        check close(sim.score(seat),
          sim.workerNet[sim.workerIndex[seat]] / (shifts * WorkerScoreScale))
    ## The worker on machine 1 toiled for a zero share: strictly negative.
    check sim.score(sim.workerSeat[0]) < 0.0
    ## The three that never lifted a finger were paid without effort.
    for worker in 1 ..< Machines:
      check sim.score(sim.workerSeat[worker]) > 0.0
    let results = sim.resultsJson()
    check results["names"].len == Seats
    check results["scores"].len == Seats
    check results["roles"].len == Seats
    check results["pay"].len == Seats
    check results["units"].len == Seats
    check close(results["pay"][sim.managerSeat].getFloat(), 0.0)
    check results["units"][sim.managerSeat].getInt() == 0
    check close(results["revenue"].getFloat() - results["wages"].getFloat(),
      results["profit"].getFloat())
    check results["shifts"].getInt() == 6
    check results["maxShifts"].getInt() == 6
    check results["reason"].getStr() == "complete"

  test "an idle firm scores exactly zero everywhere":
    var sim = initSim(fixtureConfig(shifts = 4, seed = 2))
    while not sim.done:
      sim.memo(@["A", "A", "A", "B"], 40, @[25, 25, 25, 25])
      sim.work(sim.currentSetups(), [0, 0, 0, 0], [0, 0, 0, 0])
    for seat in 0 ..< Seats:
      check sim.score(seat) == 0.0

  test "endings: complete, deadline, and nothing after":
    var sim = initSim(fixtureConfig(shifts = 5, seed = 13))
    while not sim.done:
      sim.memo(@["A", "A", "A", "B"], 40, @[25, 25, 25, 25])
      sim.work(sim.currentSetups(), [6, 6, 6, 6], [3, 3, 3, 3])
    check sim.reason == "complete"
    check sim.shiftsPlayed == 5
    check sim.events[^1].kind == evEnd
    check sim.events[^2].kind == evSettle
    check sim.pendingSeats().len == 0
    expect FirmError:
      sim.applyWork(sim.workerSeat[0], "A", 6, 3, "", "", false)

    var short = initSim(fixtureConfig(shifts = 8, seed = 13))
    short.memo(@["A", "A", "A", "B"], 40, @[25, 25, 25, 25])
    short.work(short.currentSetups(), [6, 6, 6, 6], [3, 3, 3, 3])
    short.memo(@["A", "A", "A", "B"], 40, @[25, 25, 25, 25])
    short.work(short.currentSetups(), [6, 6, 6, 6], [3, 3, 3, 3])
    short.endEarly()
    check short.reason == "deadline"
    check short.shiftsPlayed == 2
    check short.resultsJson()["reason"].getStr() == "deadline"
    check close(short.score(short.managerSeat),
      short.firmProfit / (2.0 * ManagerScoreScale))
    let eventsAfter = short.events.len
    short.endEarly()
    check short.events.len == eventsAfter

    var stillborn = initSim(fixtureConfig(shifts = 8, seed = 13))
    stillborn.endEarly()
    check stillborn.shiftsPlayed == 0
    for seat in 0 ..< Seats:
      check stillborn.score(seat) == 0.0

suite "replay":
  test "events round-trip through JSON, one of every kind":
    var sim = initSim(fixtureConfig(shifts = 4, seed = 17))
    while not sim.done:
      sim.memo(@["B", "A", "A", "B"], 45, @[40, 30, 20, 10], "hold the line",
        "manager notes")
      sim.work(["B", "A", "A", "B"], [7, 6, 5, 4], [3, 3, 3, 3],
        report = "all good")
    var kinds = initHashSet[EventKind]()
    for event in sim.events:
      kinds.incl(event.kind)
      let back = eventFromJson(eventToJson(event))
      check back.kind == event.kind
      check back.shift == event.shift
      check back.seat == event.seat
      check back.worker == event.worker
      check back.line == event.line
      check back.run == event.run
      check back.maint == event.maint
      check back.say == event.say
      check back.text == event.text
      check back.scripted == event.scripted
      check back.demandA == event.demandA
      check back.demandB == event.demandB
      check back.payroll == event.payroll
      check back.orders == event.orders
      check back.split == event.split
      check back.units == event.units
      check back.condition == event.condition
      check back.soldA == event.soldA
      check back.soldB == event.soldB
      check back.surplusA == event.surplusA
      check back.surplusB == event.surplusB
      check close(back.revenue, event.revenue)
      check close(back.pool, event.pool)
      check close(back.profit, event.profit)
      check back.obeyed == event.obeyed
      check back.idle == event.idle
      check back.machines.len == event.machines.len
      for index in 0 ..< event.machines.len:
        check back.machines[index].setup == event.machines[index].setup
        check back.machines[index].order == event.machines[index].order
        check back.machines[index].condition ==
          event.machines[index].condition
        check back.machines[index].units == event.machines[index].units
    check kinds.len == 6

  test "a recorded episode re-derives frame by frame":
    let config = fixtureConfig(shifts = 6, seed = 23)
    var live = initSim(config)
    var shift = 0
    while not live.done:
      live.memo(@["A", "B", "A", "B"], 30 + shift, @[25, 25, 25, 25],
        "shift " & $shift)
      live.work(["A", "B", "A", "B"], [6, 7, 8, 0], [3, 3, 2, 0],
        report = "report " & $shift)
      inc shift
    let frames = replayMatch(config, live.events)
    check frames.len == live.events.len + 1
    check $frames[^1].tableStateJson() == $live.tableStateJson()
    check frames[^1].reason == "complete"

    var short = initSim(config)
    short.memo(@["A", "A", "A", "B"], 40, @[25, 25, 25, 25])
    short.work(short.currentSetups(), [6, 6, 6, 6], [3, 3, 3, 3])
    short.endEarly()
    let shortFrames = replayMatch(config, short.events)
    check shortFrames[^1].done
    check shortFrames[^1].reason == "deadline"
    check shortFrames[^1].shiftsPlayed == 1

  test "the spectator frame tells a scripted seat from a live one":
    ## The frame's per-seat `scripted` key was hard-coded false, so a replay
    ## claimed every seat was LLM-driven even on an all-baseline table.
    let config = fixtureConfig(shifts = 4, seed = 31)
    var live = initSim(config)
    live.memo(@["A", "A", "A", "B"], 40, @[25, 25, 25, 25], scripted = false)
    check not live.tableStateJson()["seats"][live.managerSeat][
      "scripted"].getBool()
    for worker in 0 ..< Machines:
      live.applyWork(live.workerSeat[worker], "A", 6, 3, "", "", worker == 1)
    let frame = live.tableStateJson()
    check frame["seats"][live.workerSeat[1]]["scripted"].getBool()
    check not frame["seats"][live.workerSeat[0]]["scripted"].getBool()
    check not frame["seats"][live.managerSeat]["scripted"].getBool()
    ## The viewer derives its frames from the same re-derivation, so the
    ## provenance has to survive the round trip through the event log.
    let frames = replayMatch(config, live.events)
    check $frames[^1].tableStateJson() == $frame

  test "a tampered recording is rejected":
    let config = fixtureConfig(shifts = 5, seed = 29)
    var live = initSim(config)
    live.memo(@["A", "A", "A", "B"], 40, @[25, 25, 25, 25])
    live.work(live.currentSetups(), [6, 6, 6, 6], [3, 3, 3, 3])
    var settleTampered = live.events
    for index in 0 ..< settleTampered.len:
      if settleTampered[index].kind == evSettle:
        settleTampered[index].revenue += 1.0
    expect FirmError:
      discard replayMatch(config, settleTampered)
    var shiftTampered = live.events
    for index in countdown(shiftTampered.high, 0):
      if shiftTampered[index].kind == evShift:
        shiftTampered[index].machines[0].condition += 1
        break
    expect FirmError:
      discard replayMatch(config, shiftTampered)
