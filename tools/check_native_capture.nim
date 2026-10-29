## Reconstruct a completed native fixture independently from its applied commands.
## Synthetic loopback receipts prove capture mechanics, never teacher authorization.
import std/[base64, json, os, strutils]
import crunchy
import firm/[sim, llm, prompts, native_capture]

proc checkFailedCohort(args: seq[string]) =
  ## Separate strict mode for the frozen receipt/scalar negative; positive mode is unchanged.
  let configNode = parseFile(args[0])
  var config = defaultGameConfig()
  config.update($configNode)
  config = config.sampleEpisode()
  doAssert config.shifts == 8 and config.seed == 9 and config.reports
  doAssert config.turnDelayMs == 400 and config.llmTimeoutSeconds == 30
  let selection = promptSelection(configNode)
  let operatorPrompt = readFile(args[4])
  let frozen = parseFile(args[5])
  var rows, calls: seq[JsonNode]
  var episode: JsonNode
  for line in lines(args[1]):
    let row = parseJson(line)
    if row["event_type"].getStr() == "decision": rows.add(row)
    else:
      doAssert episode == nil
      episode = row
  for line in lines(args[3]): calls.add(parseJson(line))
  doAssert rows.len == 40 and calls.len == 41 and frozen["matrix"].len == 41
  doAssert episode != nil and episode["status"].getStr() == "failed"
  var game = initSim(config)
  let root = initialRoot(game)
  let identities = identities(game)
  var cursor, originalAttempts, forensics, accepted, rejected, duplicateAttempts: int
  var firstReceipt = ""
  while not game.done:
    let before = game
    let preHash = before.nativeStateHash()
    for seat in before.orderedSeats():
      let row = rows[cursor]
      doAssert row["seat"].getStr() == $seat
      doAssert row["decision_id"].getStr() == "shift-" & $before.shift & "-seat-" & $seat
      let isUnsafe = (before.shift == 0 and seat in [1, 2]) or
        (before.shift == 1 and seat == 1)
      let isDuplicate = before.shift == 0 and seat == 0
      var observation = row["observation"]
      var attempts = row["attempts"]
      var command = row["executed_action"]
      var unsafeEvidence = newJArray()
      if isUnsafe:
        inc forensics
        doAssert row["action_status"].getStr() == "rejected"
        doAssert command.kind == JNull and row["selected_attempt_id"].kind == JNull
        doAssert attempts.len == 0
        let originalBytes = decode(observation["invalid_native_evidence_json_b64"].getStr())
        doAssert sha256(originalBytes).toHex.toLowerAscii() ==
          observation["invalid_native_evidence_sha256"].getStr()
        let original = parseJson(originalBytes)
        doAssert original["actual_source"].getStr() == "model"
        observation = original["observation"]
        attempts = original["attempts"]
        command = original["executed_action"]
        unsafeEvidence = original["unsafe_native_evidence"]
        let requiredStages = if before.shift == 1:
            @["decoded response envelope serialization"]
          elif seat == 1:
            @["raw response entity", "decoded response envelope serialization"]
          else: @["decoded response envelope serialization", "decoded completion text"]
        doAssert unsafeEvidence.len == requiredStages.len
        var observedStages: seq[string]
        for witness in unsafeEvidence:
          let stage = witness["stage"].getStr()
          doAssert stage in requiredStages and stage notin observedStages
          observedStages.add(stage)
        doAssert row["observation"]["native_execution"]["native_applied"].getBool()
        doAssert row["observation"]["native_execution"]["applied_attempt_id"] ==
          observation["native_execution"]["applied_attempt_id"]
      if isUnsafe or isDuplicate:
        inc rejected
        doAssert row["action_status"].getStr() == "rejected"
        doAssert row["selected_attempt_id"].kind == JNull
      else:
        inc accepted
        doAssert row["action_status"].getStr() == "accepted"
        doAssert row["selected_attempt_id"] == attempts[0]["attempt_id"]
        doAssert attempts[0]["accepted"].getBool()
        doAssert row["prompt"] == attempts[0]["prompt"]
      doAssert observation["native_initial_root"] == root
      doAssert observation["scenario_family"].getStr() == identities.family
      doAssert observation["task_identity"].getStr() == identities.task
      doAssert observation["prompt_selection"] == selection.selectionMetadata()
      doAssert observation["pre_native_sha256"].getStr() == preHash
      var privateView = copy(observation)
      for key in ["native_initial_root", "scenario_family", "task_identity",
          "prompt_selection", "pre_native_sha256", "native_parsed_proposals",
          "native_requests", "native_execution", "capture_errors"]:
        if privateView.hasKey(key): privateView.delete(key)
      doAssert privateView == before.playerStateJson(seat)
      doAssert attempts.len == (if isDuplicate: 2 else: 1)
      doAssert observation["native_requests"].len == attempts.len
      var decoded: Decision
      for index in 0 ..< attempts.len:
        let attempt = attempts[index]
        inc originalAttempts
        var wire, expected: JsonNode
        for call in calls:
          if call["slot"].getInt() == seat and call["shift"].getInt() == before.shift and
              call["native_attempt_zero_based"].getInt() == index:
            doAssert wire == nil
            wire = call
        for fixture in frozen["matrix"]:
          if fixture["seat"].getInt() == seat and fixture["shift"].getInt() == before.shift and
              fixture["native_attempt_zero_based"].getInt() == index:
            doAssert expected == nil
            expected = fixture
        doAssert wire != nil and expected != nil
        doAssert wire["response_body_b64"] == expected["response_body_b64"]
        doAssert wire["call_id"] == expected["call_id"]
        doAssert wire["request_id"] == expected["request_id"]
        doAssert attempt["platform_call_id"] == wire["call_id"]
        doAssert attempt["provider_request_id"] == wire["request_id"]
        doAssert attempt["response_body_b64"] == wire["response_body_b64"]
        doAssert attempt["response_complete"].getBool() and attempt["response_reader_joined"].getBool()
        doAssert attempt["http_status"].getInt() == 200
        let request = observation["native_requests"][index]
        doAssert request["body_b64"] == wire["request_body_b64"]
        doAssert request["raw_body"].getStr() == decode(wire["request_body_b64"].getStr())
        doAssert attempt["request"] == wire["request"]
        var expectedUser = before.userPrompt(seat, operatorPrompt)
        if index > 0:
          expectedUser.add("\nYour previous reply was invalid. Respond with ONLY the requested JSON object.")
        doAssert attempt["request"]["system"].getStr() == before.systemPrompt(seat, selection)
        doAssert attempt["request"]["messages"][0]["content"].getStr() == expectedUser
        doAssert attempt["prompt"] == %*[
          {"role": "system", "content": before.systemPrompt(seat, selection)},
          {"role": "user", "content": expectedUser}]
        let body = decode(wire["response_body_b64"].getStr())
        let payload = parseJson(body)
        let text = payload["content"][0]["text"].getStr()
        if isDuplicate:
          inc duplicateAttempts
          if index == 0: firstReceipt = attempt["platform_call_id"].getStr()
          else:
            doAssert attempt["platform_call_id"].getStr() == firstReceipt
            doAssert attempt["rejection_reason"].kind == JString
          doAssert not attempt["accepted"].getBool()
        if isDuplicate and index == 0:
          var failed = false
          try: discard before.parseReply(seat, extractJsonObject(text))
          except FirmError: failed = true
          doAssert failed
          continue
        decoded = before.parseReply(seat, extractJsonObject(text))
        doAssert before.decisionJson(seat, decoded) == command
        doAssert attempt["parsed_action"] == command
        doAssert command == expected["expected_native_action"] and command == wire["action"]
        for witness in unsafeEvidence:
          doAssert witness["attempt_id"] == attempt["attempt_id"]
          let bytes = decode(witness["bytes_b64"].getStr())
          doAssert sha256(bytes).toHex.toLowerAscii() == witness["sha256"].getStr()
          case witness["stage"].getStr()
          of "raw response entity": doAssert bytes == body
          of "decoded response envelope serialization": doAssert bytes == $payload
          of "decoded completion text": doAssert bytes == text
          else: doAssert false, "unknown forensic byte provenance"
      let startEvent = game.events.len
      if game.isManager(seat):
        game.applyMemo(seat, decoded.orders, decoded.payroll, decoded.split,
          decoded.say, decoded.notes, false)
      else:
        game.applyWork(seat, decoded.line, decoded.run, decoded.maint,
          decoded.say, decoded.notes, false)
      var expectedEvents = newJArray()
      for index in startEvent ..< game.events.len:
        var event = game.events[index].eventToJson()
        if event{"seat"}.getInt(-1) != seat and event.hasKey("text"): event.delete("text")
        expectedEvents.add(event)
      let execution = observation["native_execution"]
      doAssert execution["native_applied"].getBool() and execution["origin"].getStr() == "model"
      doAssert execution["applied_attempt_id"] == attempts[attempts.len - 1]["attempt_id"]
      doAssert execution["events"] == expectedEvents
      doAssert execution["events_sha256"].getStr() == sha256($expectedEvents).toHex.toLowerAscii()
      doAssert execution["post_native_sha256"].getStr() == game.nativeStateHash()
      if isUnsafe:
        doAssert row["observation"]["native_execution"]["post_native_sha256"] ==
          execution["post_native_sha256"]
      inc cursor
  let replay = parseFile(args[2])
  var expectedEvents = newJArray()
  var recordedEvents: seq[GameEvent]
  for event in game.events: expectedEvents.add(event.eventToJson())
  doAssert replay["events"] == expectedEvents
  for event in replay["events"]: recordedEvents.add(eventFromJson(event))
  let reconstructed = replayMatch(config, recordedEvents)
  doAssert reconstructed.len > 0 and reconstructed[^1].resultsJson() == game.resultsJson()
  doAssert replay["results"] == game.resultsJson()
  doAssert episode["seed_family"].getStr() == identities.family
  var privateOutcome = copy(episode["outcome"])
  doAssert privateOutcome["capture_errors"].len > 0
  privateOutcome.delete("capture_errors")
  doAssert privateOutcome == game.resultsJson()
  doAssert cursor == 40 and originalAttempts == 41 and forensics == 3
  doAssert accepted == 36 and rejected == 4 and duplicateAttempts == 2
  echo $(%*{"status": "PASS", "mode": "frozen-failed-cohort",
    "full_native_shifts": game.shiftsPlayed, "decisions": cursor,
    "exact_HTTP_joins": originalAttempts, "forensic_rows": forensics,
    "historical_accepted_rows": accepted, "rejected_rows": rejected,
    "duplicate_attempts": duplicateAttempts, "private_episode_status": "failed",
    "SDK_complete_units_expected": 0, "provider_calls": 0,
    "teacher_authorized": false, "physical_family": identities.family,
    "native_results": game.resultsJson()})

proc checkProfile(args: seq[string]) =
  ## Frozen residual profile only; completed-positive and StageB modes stay unchanged.
  let configNode = parseFile(args[0])
  let plan = parseFile(args[5])
  let mixed = plan["profile"].getStr() == "mixed-control-transport-publication"
  doAssert mixed or plan["profile"].getStr() == "silent-strict-pair"
  var config = defaultGameConfig()
  config.update($configNode)
  config = config.sampleEpisode()
  doAssert config.seed == 9 and config.shifts == 8 and config.turnDelayMs == 400
  doAssert config.llmTimeoutSeconds == 30 and config.playerConnectTimeoutSeconds == 180
  doAssert config.reports == mixed
  let selection = promptSelection(configNode)
  let operatorPrompt = readFile(args[4])
  var game = initSim(config)
  let root = initialRoot(game)
  let identities = identities(game)
  var rows, calls: seq[JsonNode]
  var episode: JsonNode
  for line in lines(args[1]):
    let row = parseJson(line)
    if row["event_type"].getStr() == "decision": rows.add(row)
    else:
      doAssert episode == nil
      episode = row
  for line in lines(args[3]): calls.add(parseJson(line))
  doAssert rows.len == 40 and calls.len == (if mixed: 23 else: 40)
  doAssert episode != nil and episode["status"].getStr() == "completed"
  var cursor, attemptsSeen, accepted, rejected, missing, fallback, transportGaps: int
  while not game.done:
    let before = game
    let preHash = before.nativeStateHash()
    for seat in before.orderedSeats():
      let row = rows[cursor]
      let observation = row["observation"]
      let execution = observation["native_execution"]
      let attempts = row["attempts"]
      doAssert row["seat"].getStr() == $seat
      doAssert row["decision_id"].getStr() == "shift-" & $before.shift & "-seat-" & $seat
      doAssert observation["native_initial_root"] == root
      doAssert observation["scenario_family"].getStr() == identities.family
      doAssert observation["task_identity"].getStr() == identities.task
      doAssert observation["prompt_selection"] == selection.selectionMetadata()
      doAssert observation["pre_native_sha256"].getStr() == preHash
      var privateView = copy(observation)
      for key in ["native_initial_root", "scenario_family", "task_identity",
          "prompt_selection", "pre_native_sha256", "native_parsed_proposals",
          "native_requests", "native_execution"]:
        privateView.delete(key)
      doAssert privateView == before.playerStateJson(seat)
      let isExternal = mixed and seat == 0
      let isScript = mixed and seat == 4
      let isFallback = mixed and (before.shift == 7 and seat in [1, 2, 3] or
        before.shift == 0 and seat == 1 or before.shift == 6 and seat == 2)
      let expectedOrigin = if isExternal: "external"
        elif isScript: "scripted" elif isFallback: "fallback" else: "model"
      doAssert execution["origin"].getStr() == expectedOrigin
      doAssert execution["native_applied"].getBool()
      var decision: Decision
      var eligible = true
      if isScript or isFallback:
        decision = scriptedAction(before, seat, skSteady)
      elif isExternal:
        var action: JsonNode
        for cell in plan["external_actions"]:
          if cell["shift"].getInt() == before.shift and cell["seat"].getInt() == seat:
            doAssert action == nil
            action = cell["action"]
        doAssert action != nil
        decision = before.parseReply(seat, action)
      var expectedAttempts = 0
      for cell in plan["matrix"]:
        if cell["shift"].getInt() == before.shift and cell["seat"].getInt() == seat:
          inc expectedAttempts
      doAssert attempts.len == expectedAttempts
      doAssert observation["native_requests"].len == expectedAttempts
      for index in 0 ..< expectedAttempts:
        inc attemptsSeen
        let attempt = attempts[index]
        var wire, cell: JsonNode
        for candidate in calls:
          if candidate["shift"].getInt() == before.shift and candidate["slot"].getInt() == seat and
              candidate["native_attempt_zero_based"].getInt() == index:
            doAssert wire == nil
            wire = candidate
        for candidate in plan["matrix"]:
          if candidate["shift"].getInt() == before.shift and candidate["seat"].getInt() == seat and
              candidate["native_attempt_zero_based"].getInt() == index:
            doAssert cell == nil
            cell = candidate
        doAssert wire != nil and cell != nil
        doAssert wire["response_body_b64"] == cell["response_body_b64"]
        doAssert wire["call_id"] == cell["call_id"] and wire["request_id"] == cell["request_id"]
        let requested = observation["native_requests"][index]
        doAssert requested["body_b64"] == wire["request_body_b64"]
        doAssert requested["raw_body"].getStr() == decode(wire["request_body_b64"].getStr())
        doAssert attempt["request"] == wire["request"]
        var user = before.userPrompt(seat, operatorPrompt)
        if index > 0: user.add("\nYour previous reply was invalid. Respond with ONLY the requested JSON object.")
        doAssert attempt["request"]["system"].getStr() == before.systemPrompt(seat, selection)
        doAssert attempt["request"]["messages"][0]["content"].getStr() == user
        doAssert attempt["prompt"] == %*[
          {"role":"system", "content":before.systemPrompt(seat, selection)},
          {"role":"user", "content":user}]
        doAssert attempt["response_reader_joined"].getBool()
        if cell["delivery"].getStr() == "partial_timeout":
          inc transportGaps
          doAssert attempt["response_complete"] == %false
          for key in ["http_status", "platform_call_id", "provider_request_id", "raw_response", "response_body_b64", "response_headers"]:
            doAssert attempt[key].kind == JNull
          doAssert requested["transport_gap"].kind == JString
          doAssert not attempt["accepted"].getBool()
          continue
        doAssert attempt["response_complete"].getBool()
        doAssert attempt["http_status"].getInt() == cell["http_status"].getInt()
        doAssert attempt["response_body_b64"] == wire["response_body_b64"]
        doAssert attempt["platform_call_id"] == wire["call_id"]
        doAssert attempt["provider_request_id"] == wire["request_id"]
        doAssert attempt["raw_response"].getStr() == decode(wire["response_body_b64"].getStr())
        if cell["http_status"].getInt() != 200:
          doAssert not attempt["accepted"].getBool() and attempt["rejection_reason"].kind == JString
          continue
        let payload = parseJson(attempt["raw_response"].getStr())
        let text = payload["content"][0]["text"].getStr()
        doAssert attempt["response"].getStr() == text
        decision = before.parseReply(seat, extractJsonObject(text))
        let parsed = before.decisionJson(seat, decision)
        doAssert attempt["parsed_action"] == parsed
        if not mixed:
          eligible = cell["strict_eligible"].getBool()
          doAssert parsed == cell["expected_native_action"]
        else: doAssert parsed == cell["offered_model_action"]
      let command = before.decisionJson(seat, decision)
      doAssert row["executed_action"] == command
      if isExternal or isScript:
        inc missing
        doAssert row["action_status"].getStr() == "missing" and attempts.len == 0
        doAssert row["selected_attempt_id"].kind == JNull
        doAssert execution["applied_attempt_id"].kind == JNull
      elif isFallback:
        inc fallback
        doAssert row["action_status"].getStr() == "fallback"
        doAssert row["fallback_origin"].getStr() == "steady" and row["selected_attempt_id"].kind == JNull
      elif eligible:
        inc accepted
        doAssert row["action_status"].getStr() == "accepted"
        doAssert row["selected_attempt_id"] == attempts[attempts.len - 1]["attempt_id"]
        doAssert attempts[attempts.len - 1]["accepted"].getBool()
        doAssert row["prompt"] == attempts[attempts.len - 1]["prompt"]
      else:
        inc rejected
        doAssert row["action_status"].getStr() == "rejected" and row["selected_attempt_id"].kind == JNull
        doAssert not attempts[attempts.len - 1]["accepted"].getBool()
      let startEvent = game.events.len
      # Existing native replay keeps the prior scripted flag for external0; capture origin is explicit external.
      let wasScripted = isExternal or isScript or isFallback
      if game.isManager(seat):
        game.applyMemo(seat, decision.orders, decision.payroll, decision.split,
          decision.say, decision.notes, wasScripted)
      else:
        game.applyWork(seat, decision.line, decision.run, decision.maint,
          decision.say, decision.notes, wasScripted)
      var expectedEvents = newJArray()
      for index in startEvent ..< game.events.len:
        var event = game.events[index].eventToJson()
        if event{"seat"}.getInt(-1) != seat and event.hasKey("text"): event.delete("text")
        expectedEvents.add(event)
      doAssert execution["events"] == expectedEvents
      doAssert execution["events_sha256"].getStr() == sha256($expectedEvents).toHex.toLowerAscii()
      doAssert execution["post_native_sha256"].getStr() == game.nativeStateHash()
      inc cursor
  let replay = parseFile(args[2])
  var expectedEvents = newJArray()
  var recordedEvents: seq[GameEvent]
  for event in game.events: expectedEvents.add(event.eventToJson())
  doAssert replay["events"] == expectedEvents
  for event in replay["events"]: recordedEvents.add(eventFromJson(event))
  let reconstructed = replayMatch(config, recordedEvents)
  doAssert reconstructed.len > 0 and reconstructed[^1].resultsJson() == game.resultsJson()
  doAssert replay["results"] == game.resultsJson() and episode["outcome"] == game.resultsJson()
  doAssert episode["seed_family"].getStr() == identities.family
  if mixed:
    doAssert accepted == 19 and fallback == 5 and missing == 16 and rejected == 0 and transportGaps == 1
  else:
    doAssert accepted == plan["strict_accepted_expected"].getInt()
    doAssert rejected == plan["strict_excluded_expected"].getInt()
    doAssert missing == 0 and fallback == 0 and transportGaps == 0
  doAssert attemptsSeen == calls.len and cursor == 40
  echo $(%*{"status":"PASS", "mode":plan["profile"], "full_native_shifts":8,
    "native_decisions":cursor, "HTTP":attemptsSeen, "accepted":accepted,
    "rejected":rejected, "fallback":fallback, "missing":missing,
    "transport_unavailable_gaps":transportGaps, "physical_family":identities.family,
    "causal_condition":identities.task, "provider_calls":0, "teacher_authorized":false,
    "private_publication_success_claimed":not mixed})

proc checkNativeTextBoundary() =
  ## Native parser -> apply -> state witnesses; no HTTP or teacher data.
  var config = defaultGameConfig()
  config.seed = 9
  config.sampled = true
  for seat in 0 ..< Seats:
    config.players.add(PlayerConfig(name: "fixture-" & $seat))
    config.tokens.add("fixture-token-" & $seat)
  let low = parseJson("\"\\udc00\"").getStr()
  let raw = "\x80"
  let pair = parseJson("\"\\ud83d\\udc1d\"").getStr()
  let accent = "caf\xc3\xa9"
  var passed: seq[string]
  proc action(manager: bool): JsonNode =
    if manager: %*{"orders": ["B", "A", "B", "A"], "payroll": 40,
      "split": [25, 25, 25, 25], "directive": "valid memo", "notes": "valid notes"}
    else: %*{"line": "A", "run": 6, "maint": 3, "report": "valid report", "notes": "valid notes"}
  proc apply(game: var Sim, seat: int, decision: Decision) =
    if game.isManager(seat):
      game.applyMemo(seat, decision.orders, decision.payroll, decision.split,
        decision.say, decision.notes, false)
    else:
      game.applyWork(seat, decision.line, decision.run, decision.maint,
        decision.say, decision.notes, false)
  proc rejected(manager: bool, field, value, name: string, direct: bool) =
    var game = initSim(config)
    let seat = if manager: game.managerSeat else: game.workerSeat[0]
    let before = game.nativeStateHash()
    var payload = action(manager)
    payload[field] = %value
    var failed = false
    try:
      if direct:
        if manager:
          game.applyMemo(seat, @["B", "A", "B", "A"], 40, @[25, 25, 25, 25],
            (if field == "directive": value else: "valid memo"),
            (if field == "notes": value else: "valid notes"), false)
        else:
          game.applyWork(seat, "A", 6, 3,
            (if field == "report": value else: "valid report"),
            (if field == "notes": value else: "valid notes"), false)
      else:
        discard game.parseReply(seat, payload)
    except FirmError as error:
      doAssert error.msg == "native text must be Unicode scalar UTF-8"
      failed = true
    doAssert failed and game.nativeStateHash() == before, name
    passed.add(name)
  for manager in [true, false]:
    for field in (if manager: @["notes", "directive"] else: @["notes", "report"]):
      let name = (if manager: "manager-" else: "worker-") & field
      rejected(manager, field, low, "parse-low-" & name, false)
      rejected(manager, field, low, "apply-low-" & name, true)
    rejected(manager, "notes", raw, "parse-raw80-" & $manager, false)
    rejected(manager, "notes", raw, "apply-raw80-" & $manager, true)
    var game = initSim(config)
    let seat = if manager: game.managerSeat else: game.workerSeat[0]
    var payload = action(manager)
    payload["notes"] = %(if manager: accent else: pair)
    let sayField = if manager: "directive" else: "report"
    payload[sayField] = %(if manager: pair else: accent)
    let decision = game.parseReply(seat, payload)
    game.apply(seat, decision)
    doAssert game.notes[seat] == (if manager: accent else: pair)
    if manager: doAssert game.directive == pair
    else: doAssert game.reports[game.workerIndex[seat]] == accent
    passed.add("valid-accent-pair-" & $manager)
    let shift = game.shift
    for other in game.orderedSeats():
      if other == seat: continue
      game.apply(other, scriptedAction(game, other, skSteady))
    doAssert game.shift == shift + 1
    let retained = game.notes[seat]
    let directive = game.directive
    var keep = action(manager)
    keep["notes"] = %""
    if manager: keep["directive"] = %""
    let empty = game.parseReply(seat, keep)
    doAssert empty.notes == ""
    game.apply(seat, empty)
    doAssert game.notes[seat] == retained
    if manager: doAssert empty.say == "" and game.directive == directive
    passed.add("empty-command-KEEP-" & $manager)
  doAssert passed.len == 16
  echo $(%*{"status":"PASS", "mode":"native-text-boundary-vectors", "cases":passed,
    "case_count":passed.len, "ordinary_episodes":0, "HTTP":0, "provider_calls":0,
    "teacher_authorized":false})

proc checkNotebookCohort(args: seq[string]) =
  ## Same frozen poison replies; new native rejection must keep public play safe.
  let configNode = parseFile(args[0])
  var config = defaultGameConfig()
  config.update($configNode)
  config = config.sampleEpisode()
  doAssert config.seed == 9 and config.shifts == 8 and config.reports
  doAssert config.turnDelayMs == 400 and config.llmTimeoutSeconds == 30
  doAssert config.playerConnectTimeoutSeconds == 180 and config.maxOutputTokens == 800
  let selection = promptSelection(configNode)
  let operatorPrompt = readFile(args[4])
  let frozen = parseFile(args[5])
  doAssert frozen["matrix"].len == 80
  var rows, calls: seq[JsonNode]
  var episode: JsonNode
  for line in lines(args[1]):
    let row = parseJson(line)
    if row["event_type"].getStr() == "decision": rows.add(row)
    else:
      doAssert episode == nil
      episode = row
  for line in lines(args[3]): calls.add(parseJson(line))
  doAssert rows.len == 40 and calls.len == 42
  doAssert episode != nil and episode["status"].getStr() == "failed"
  var game = initSim(config)
  let root = initialRoot(game)
  let identity = identities(game)
  doAssert game.managerSeat == 3 and game.workerSeat == [0, 1, 2, 4]
  var cursor, joined, forensic, accepted, fallback, rejectedAttempts, witnesses: int
  while not game.done:
    let before = game
    let preHash = before.nativeStateHash()
    for seat in before.orderedSeats():
      let row = rows[cursor]
      let bad = before.shift == 0 and seat in [0, 1]
      let unsafe = before.shift == 0 and seat == 1
      var observation = row["observation"]
      var attempts = row["attempts"]
      var actual = row["executed_action"]
      var evidence = newJArray()
      doAssert row["seat"].getStr() == $seat
      doAssert row["decision_id"].getStr() == "shift-" & $before.shift & "-seat-" & $seat
      if unsafe:
        inc forensic
        doAssert actual.kind == JNull and row["selected_attempt_id"].kind == JNull
        doAssert attempts.len == 0 and row["action_status"].getStr() == "fallback"
        let bytes = decode(observation["invalid_native_evidence_json_b64"].getStr())
        doAssert sha256(bytes).toHex.toLowerAscii() == observation["invalid_native_evidence_sha256"].getStr()
        let original = parseJson(bytes)
        doAssert original["actual_source"].getStr() == "fallback"
        observation = original["observation"]
        attempts = original["attempts"]
        actual = original["executed_action"]
        evidence = original["unsafe_native_evidence"]
        doAssert evidence.len == 6
      else:
        doAssert not observation.hasKey("invalid_native_evidence_json_b64")
      doAssert observation["native_initial_root"] == root
      doAssert observation["scenario_family"].getStr() == identity.family
      doAssert observation["task_identity"].getStr() == identity.task
      doAssert observation["prompt_selection"] == selection.selectionMetadata()
      doAssert observation["pre_native_sha256"].getStr() == preHash
      var view = copy(observation)
      for key in ["native_initial_root", "scenario_family", "task_identity",
          "prompt_selection", "pre_native_sha256", "native_parsed_proposals",
          "native_requests", "native_execution", "capture_errors"]:
        if view.hasKey(key): view.delete(key)
      doAssert view == before.playerStateJson(seat)
      doAssert attempts.len == (if bad: 2 else: 1)
      doAssert observation["native_requests"].len == attempts.len
      var decision: Decision
      if bad: decision = scriptedAction(before, seat, skSteady)
      for index in 0 ..< attempts.len:
        inc joined
        let attempt = attempts[index]
        var wire, cell: JsonNode
        for candidate in calls:
          if candidate["slot"].getInt() == seat and candidate["shift"].getInt() == before.shift and
              candidate["native_attempt_zero_based"].getInt() == index:
            doAssert wire == nil
            wire = candidate
        for candidate in frozen["matrix"]:
          if candidate["seat"].getInt() == seat and candidate["shift"].getInt() == before.shift and
              candidate["native_attempt_zero_based"].getInt() == index:
            doAssert cell == nil
            cell = candidate
        doAssert wire != nil and cell != nil
        for key in ["response_body_b64", "call_id", "request_id"]: doAssert wire[key] == cell[key]
        doAssert attempt["response_body_b64"] == wire["response_body_b64"]
        doAssert attempt["platform_call_id"] == wire["call_id"]
        doAssert attempt["provider_request_id"] == wire["request_id"]
        doAssert attempt["response_complete"].getBool() and attempt["response_reader_joined"].getBool()
        doAssert attempt["http_status"].getInt() == 200
        var callHeaders, requestHeaders: int
        for key, value in attempt["response_headers"]:
          case key.toLowerAscii()
          of "content-type": doAssert value.getStr() == "application/json"
          of "x-softmax-llm-call-id":
            inc callHeaders
            doAssert value == wire["call_id"]
          of "request-id", "x-request-id":
            inc requestHeaders
            doAssert value == wire["request_id"]
          else: doAssert false, "unexpected retained response header"
        doAssert callHeaders == 1 and requestHeaders == 1
        let requested = observation["native_requests"][index]
        let body = decode(wire["request_body_b64"].getStr())
        doAssert scalarUtf8(body) and requested["body_b64"] == wire["request_body_b64"]
        doAssert requested["raw_body"].getStr() == body
        doAssert attempt["request"] == parseJson(body)
        var user = before.userPrompt(seat, operatorPrompt)
        if index > 0: user.add("\nYour previous reply was invalid. Respond with ONLY the requested JSON object.")
        doAssert attempt["request"]["model"].getStr() == "anthropic/claude-haiku-4.5"
        doAssert attempt["request"]["max_tokens"].getInt() == 800
        doAssert attempt["request"]["system"].getStr() == before.systemPrompt(seat, selection)
        doAssert attempt["request"]["messages"][0]["content"].getStr() == user
        doAssert attempt["prompt"] == %*[
          {"role":"system", "content":before.systemPrompt(seat, selection)},
          {"role":"user", "content":user}]
        let response = decode(wire["response_body_b64"].getStr())
        let payload = parseJson(response)
        let text = payload["content"][0]["text"].getStr()
        if bad:
          inc rejectedAttempts
          doAssert not attempt["accepted"].getBool() and attempt["parsed_action"].kind == JNull
          doAssert attempt["rejection_reason"].getStr() == "native text must be Unicode scalar UTF-8"
          var rejected = false
          try: discard before.parseReply(seat, extractJsonObject(text))
          except FirmError as error:
            doAssert error.msg == "native text must be Unicode scalar UTF-8"
            rejected = true
          doAssert rejected
        else:
          doAssert attempt["raw_response"].getStr() == response and attempt["response"].getStr() == text
          decision = before.parseReply(seat, extractJsonObject(text))
          doAssert attempt["parsed_action"] == before.decisionJson(seat, decision)
          doAssert attempt["accepted"].getBool()
        var stages: seq[string]
        for witness in evidence:
          if witness["attempt_id"] != attempt["attempt_id"]: continue
          inc witnesses
          let original = decode(witness["bytes_b64"].getStr())
          doAssert sha256(original).toHex.toLowerAscii() == witness["sha256"].getStr()
          let stage = witness["stage"].getStr()
          doAssert stage notin stages
          stages.add(stage)
          case stage
          of "raw response entity": doAssert original == response
          of "decoded response envelope serialization": doAssert original == $payload
          of "decoded completion text": doAssert original == text
          else: doAssert false, "unexpected forensic stage"
        if unsafe:
          doAssert stages.len == 3
          doAssert attempt["raw_response"].kind == JNull and attempt["response"].kind == JNull
        else:
          doAssert stages.len == 0
          doAssert attempt["raw_response"].getStr() == response and attempt["response"].getStr() == text
      let command = before.decisionJson(seat, decision)
      doAssert actual == command
      if bad:
        inc fallback
        doAssert row["action_status"].getStr() == "fallback" and row["selected_attempt_id"].kind == JNull
        doAssert row["fallback_origin"].getStr() == "steady"
      else:
        inc accepted
        doAssert row["action_status"].getStr() == "accepted"
        doAssert row["selected_attempt_id"] == attempts[0]["attempt_id"]
        doAssert row["prompt"] == attempts[0]["prompt"]
      let startEvent = game.events.len
      if game.isManager(seat):
        game.applyMemo(seat, decision.orders, decision.payroll, decision.split,
          decision.say, decision.notes, bad)
      else:
        game.applyWork(seat, decision.line, decision.run, decision.maint,
          decision.say, decision.notes, bad)
      var events = newJArray()
      for index in startEvent ..< game.events.len:
        var event = game.events[index].eventToJson()
        if event{"seat"}.getInt(-1) != seat and event.hasKey("text"): event.delete("text")
        events.add(event)
      let execution = observation["native_execution"]
      doAssert execution["origin"].getStr() == (if bad: "fallback" else: "model")
      doAssert execution["native_applied"].getBool()
      doAssert execution["applied_attempt_id"] == (if bad: newJNull() else: attempts[0]["attempt_id"])
      doAssert execution["events"] == events
      doAssert execution["events_sha256"].getStr() == sha256($events).toHex.toLowerAscii()
      doAssert execution["post_native_sha256"].getStr() == game.nativeStateHash()
      if unsafe:
        doAssert row["observation"]["native_execution"]["post_native_sha256"] == execution["post_native_sha256"]
      if before.shift > 0:
        doAssert game.notes[2] == "CONTROL_PAIR_" & parseJson("\"\\ud83d\\udc1d\"").getStr()
        doAssert game.notes[3] == "CONTROL_CAFE_caf\xc3\xa9" and game.notes[4] == "CONTROL_ASCII_4"
        doAssert game.notes[0] == "" and game.notes[1] == ""
        doAssert command["notes"].getStr() == ""
      inc cursor
  let replay = parseFile(args[2])
  var expected = newJArray()
  var recorded: seq[GameEvent]
  for event in game.events: expected.add(event.eventToJson())
  doAssert replay["events"] == expected
  for event in replay["events"]: recorded.add(eventFromJson(event))
  let rebuilt = replayMatch(config, recorded)
  doAssert rebuilt.len > 0 and rebuilt[^1].resultsJson() == game.resultsJson()
  doAssert replay["results"] == game.resultsJson() and game.shiftsPlayed == 8
  var outcome = copy(episode["outcome"])
  doAssert outcome["capture_errors"].len > 0
  outcome.delete("capture_errors")
  doAssert outcome == game.resultsJson() and episode["seed_family"].getStr() == identity.family
  doAssert cursor == 40 and joined == 42 and forensic == 1 and accepted == 38 and fallback == 2
  doAssert rejectedAttempts == 4 and witnesses == 6
  echo $(%*{"status":"PASS", "mode":"native-notebook-cohort", "shifts":8,
    "decisions":cursor,"HTTP":joined,"forensic_rows":forensic,"accepted":accepted,
    "fallback":fallback,"native_rejected_attempts":rejectedAttempts,"unsafe_byte_witnesses":witnesses,
    "private_episode_status":"failed","SDK_complete_units_expected":0,"provider_calls":0,
    "teacher_authorized":false,"physical_family":identity.family,"native_results":game.resultsJson()})

when isMainModule:
  let args = commandLineParams()
  if args == @["--native-text-boundary"]:
    checkNativeTextBoundary()
    quit(0)
  if args.len == 7 and args[0] == "--notebook-cohort":
    checkNotebookCohort(args[1 .. ^1])
    quit(0)
  if args.len == 7 and args[0] == "--profile":
    checkProfile(args[1 .. ^1])
    quit(0)
  if args.len == 7 and args[0] == "--failed-cohort":
    checkFailedCohort(args[1 .. ^1])
    quit(0)
  doAssert args.len == 5,
    "usage: check-native-capture CONFIG TRAJECTORY REPLAY OBSERVED_HTTP OPERATOR_PROMPT"
  let configNode = parseFile(args[0])
  var config = defaultGameConfig()
  config.update($configNode)
  config = config.sampleEpisode()
  let selection = promptSelection(configNode)
  let operatorPrompt = readFile(args[4])
  var game = initSim(config)
  var rows, calls: seq[JsonNode]
  var episode: JsonNode
  for line in lines(args[1]):
    let row = parseJson(line)
    if row["event_type"].getStr() == "decision": rows.add(row)
    else:
      doAssert episode == nil
      episode = row
  for line in lines(args[3]): calls.add(parseJson(line))
  doAssert rows.len == config.shifts * Seats and calls.len == rows.len
  let root = initialRoot(game)
  let identities = identities(game)
  var cursor = 0
  var keepCommands = 0
  while not game.done:
    let before = game
    let preHash = before.nativeStateHash()
    for seat in before.orderedSeats():
      let row = rows[cursor]
      let observation = row["observation"]
      doAssert row["seat"].getStr() == $seat
      doAssert row["decision_id"].getStr() == "shift-" & $before.shift & "-seat-" & $seat
      doAssert row["action_status"].getStr() == "accepted"
      doAssert observation["native_initial_root"] == root
      doAssert observation["scenario_family"].getStr() == identities.family
      doAssert observation["task_identity"].getStr() == identities.task
      doAssert observation["prompt_selection"] == selection.selectionMetadata()
      doAssert observation["pre_native_sha256"].getStr() == preHash
      var privateView = copy(observation)
      for key in ["native_initial_root", "scenario_family", "task_identity",
          "prompt_selection", "pre_native_sha256", "native_parsed_proposals",
          "native_requests", "native_execution"]:
        privateView.delete(key)
      doAssert privateView == before.playerStateJson(seat)
      doAssert row["attempts"].len == 1
      let attempt = row["attempts"][0]
      doAssert attempt["accepted"].getBool() and attempt["origin"].getStr() == "model"
      doAssert attempt["response_complete"].getBool() and attempt["response_reader_joined"].getBool()
      doAssert attempt["http_status"].getInt() == 200
      doAssert row["selected_attempt_id"] == attempt["attempt_id"]
      doAssert observation["native_execution"]["applied_attempt_id"] == attempt["attempt_id"]
      doAssert observation["native_execution"]["native_applied"].getBool()
      var wire: JsonNode
      for call in calls:
        if call["slot"].getInt() == seat and call["shift"].getInt() == before.shift:
          doAssert wire == nil
          wire = call
      doAssert wire != nil
      doAssert attempt["platform_call_id"] == wire["call_id"]
      doAssert attempt["provider_request_id"] == wire["request_id"]
      doAssert attempt["response_body_b64"] == wire["response_body_b64"]
      doAssert attempt["raw_response"].getStr() == decode(wire["response_body_b64"].getStr())
      doAssert observation["native_requests"].len == 1
      let requested = observation["native_requests"][0]
      doAssert requested["body_b64"] == wire["request_body_b64"]
      doAssert requested["raw_body"].getStr() == decode(wire["request_body_b64"].getStr())
      doAssert attempt["request"] == wire["request"]
      doAssert attempt["request"]["system"].getStr() == before.systemPrompt(seat, selection)
      doAssert attempt["request"]["messages"][0]["content"].getStr() == before.userPrompt(seat, operatorPrompt)
      doAssert attempt["prompt"] == %*[
        {"role": "system", "content": before.systemPrompt(seat, selection)},
        {"role": "user", "content": before.userPrompt(seat, operatorPrompt)}]
      doAssert row["prompt"] == attempt["prompt"]
      let text = parseJson(attempt["raw_response"].getStr())["content"][0]["text"].getStr()
      doAssert attempt["response"].getStr() == text
      let decoded = before.parseReply(seat, extractJsonObject(text))
      let command = before.decisionJson(seat, decoded)
      doAssert command == row["executed_action"] and command == attempt["parsed_action"]
      doAssert command == wire["action"]
      if command["notes"].getStr() == "": inc keepCommands
      let startEvent = game.events.len
      if game.isManager(seat):
        game.applyMemo(seat, decoded.orders, decoded.payroll, decoded.split,
          decoded.say, decoded.notes, false)
      else:
        game.applyWork(seat, decoded.line, decoded.run, decoded.maint,
          decoded.say, decoded.notes, false)
      var expectedEvents = newJArray()
      for index in startEvent ..< game.events.len:
        var event = game.events[index].eventToJson()
        if event{"seat"}.getInt(-1) != seat and event.hasKey("text"):
          event.delete("text")
        expectedEvents.add(event)
      let execution = observation["native_execution"]
      doAssert execution["events"] == expectedEvents
      doAssert execution["events_sha256"].getStr() == sha256($expectedEvents).toHex.toLowerAscii()
      doAssert execution["post_native_sha256"].getStr() == game.nativeStateHash()
      doAssert execution["origin"].getStr() == "model"
      inc cursor
  doAssert cursor == rows.len
  let replay = parseFile(args[2])
  var actualEvents: seq[GameEvent]
  var expectedEvents = newJArray()
  for event in game.events: expectedEvents.add(event.eventToJson())
  doAssert replay["events"] == expectedEvents
  for event in replay["events"]: actualEvents.add(eventFromJson(event))
  let reconstructed = replayMatch(config, actualEvents)
  doAssert reconstructed.len > 0
  doAssert reconstructed[^1].resultsJson() == game.resultsJson()
  doAssert replay["results"] == game.resultsJson()
  doAssert episode["status"].getStr() == "completed"
  doAssert episode["seed_family"].getStr() == identities.family
  doAssert episode["outcome"] == game.resultsJson()
  echo $(%*{"status": "PASS", "full_native_shifts": game.shiftsPlayed,
    "decisions": rows.len, "matched_HTTP": calls.len, "keep_notebook_commands": keepCommands,
    "physical_family": identities.family, "causal_condition": identities.task,
    "actual_initial_root": root, "provider_calls": 0,
    "teacher_authorized": false, "native_results": game.resultsJson()})
