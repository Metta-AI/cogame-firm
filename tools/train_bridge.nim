## JSONL numeric bridge over the native Firm simulator.

import std/[hashes, json, os]
import firm/[sim, llm]

var
  game: Sim
  seats: seq[int]
  cursor: int
  decisionId: int
  choices: array[Seats, int]
  manifestPath: string
  variant: string

proc currentDecision(): JsonNode =
  let seat = seats[cursor]
  let system = systemPrompt(game, seat)
  let user = userPrompt(game, seat, "")
  %*{"kind": "decision", "game": "firm",
    "decision_id": decisionId, "seat": seat, "engine_seat": seat,
    "turn": game.shift,
    "semantic_view": {"system": system, "user": user},
    "inbox": [], "messages": [
      {"role": "system", "content": system},
      {"role": "user", "content": user}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0, "maximum": 1}},
      "required": ["choice"]}, "typed_question": newJNull()}

proc reset(command: JsonNode): JsonNode =
  doAssert command["players"].getInt() == Seats
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  variantConfig["seed"] = %(hash(command["seed"].getStr()) and 0x7FFFFFFF)
  var config = defaultGameConfig()
  config.update($variantConfig)
  config = config.sampleEpisode()
  game = initSim(config)
  seats = game.orderedSeats()
  cursor = 0
  decisionId = 0
  choices = [0, 0, 0, 0, 0]
  currentDecision()

proc encode(): JsonNode =
  let seat = seats[cursor]
  let view = game.playerStateJson(seat)
  let manager = game.isManager(seat)
  var values = newJArray()
  for name in ["standard", "silent-floor"]:
    values.add(%(if variant == name: 1 else: 0))
  for player in 0 ..< Seats:
    values.add(%(if seat == player: 1 else: 0))
  values.add(%(if manager: 1 else: 0))
  values.add(%(if manager: 0 else: 1))
  values.add(%(float(view["shift"].getInt()) / float(view["shifts"].getInt())))
  values.add(%(float(view["shiftsPlayed"].getInt()) /
    float(view["shifts"].getInt())))
  values.add(%(if game.config.reports: 1 else: 0))
  if manager:
    for field in ["demandA", "demandB", "nextA", "nextB"]:
      values.add(%(float(view["board"][field].getInt()) / 40.0))
  else:
    for unused in 0 ..< 4: values.add(%0.0)
  for machine in view["floor"]:
    values.add(%(if machine["setup"].getStr() == "A": 1 else: 0))
    values.add(%(if machine["order"].getStr() == "A": 1 else: 0))
    values.add(%(float(machine["units"].getInt()) / 20.0))
  values.add(%(float(view["payroll"].getInt()) / 60.0))
  for share in view["split"]:
    values.add(%(float(share.getInt()) / 100.0))
  if manager:
    for unused in 0 ..< 9: values.add(%0.0)
    values.add(%(view["ledger"]["revenue"].getFloat() / 1000.0))
    values.add(%(view["ledger"]["pool"].getFloat() / 1000.0))
    values.add(%(view["ledger"]["profit"].getFloat() / 1000.0))
  else:
    let own = view["own"]
    values.add(%(float(view["machine"].getInt()) / float(Machines)))
    values.add(%(if own["setup"].getStr() == "A": 1 else: 0))
    values.add(%(if own["order"].getStr() == "A": 1 else: 0))
    values.add(%(float(own["condition"].getInt()) / 100.0))
    values.add(%(float(own["run"].getInt()) / float(ShiftHours)))
    values.add(%(float(own["maint"].getInt()) / float(ShiftHours)))
    values.add(%(float(own["units"].getInt()) / 20.0))
    values.add(%(own["pay"].getFloat() / 100.0))
    values.add(%(own["toil"].getFloat() / 20.0))
    for unused in 0 ..< 3: values.add(%0.0)
  doAssert values.len == 45
  %*{"decision_id": decisionId, "values": values,
    "actions": [{"choice": 0}, {"choice": 1}]}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(command["response"].getStr())
  let choice = action["choice"].getInt()
  doAssert choice in 0 .. 1
  choices[seats[cursor]] = choice
  inc decisionId
  inc cursor
  if cursor == seats.len:
    var decisions: array[Seats, Decision]
    for seat in seats:
      let kind = if choices[seat] == 0: skSteady else: skTaskmaster
      decisions[seat] = scriptedAction(game, seat, kind)
    for seat in seats:
      let decision = decisions[seat]
      if game.isManager(seat):
        game.applyMemo(seat, decision.orders, decision.payroll,
          decision.split, decision.say, decision.notes, true)
      else:
        game.applyWork(seat, decision.line, decision.run, decision.maint,
          decision.say, decision.notes, true)
    seats = game.orderedSeats()
    cursor = 0
  let observation = if game.done:
    var scores = newJObject()
    var utilities = newJObject()
    for player in 0 ..< Seats:
      let score = game.score(player)
      scores[$player] = %score
      utilities[$player] = %(score / (abs(score) + 1.0))
    %*{"kind": "terminal", "scores": scores,
      "utilities": utilities}
  else: currentDecision()
  %*{"kind": "accepted", "action": action, "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: firm-train-bridge MANIFEST VARIANT", 1)
  manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in ["standard", "silent-floor"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": encode()
      of "teacher": %*{"response": $(%*{"choice": 0})}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
