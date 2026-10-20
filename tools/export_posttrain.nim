## Complete native shifts with exact hosted prompts and parsed replies.

import std/[json, os, osproc, strutils]
import firm/[sim, llm, prompts]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [3, 5]:
    quit("usage: firm-posttrain OUTPUT EPISODES VARIANT [PROMPT_VARIANT PROMPT_SEED]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  let selection = promptSelection(if args.len == 5:
    %*{"promptVariant": args[3], "promptSeed": parseInt(args[4])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit source before generating a pinned corpus"
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
    wordingCounts: array[2, int]
  for seed in 1 .. episodes:
    var wording = selection
    let partition = ord(seed mod 5 == 0)
    if wording.variant == pvMixed:
      wording.seed += wordingCounts[partition]
    inc wordingCounts[partition]
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config = config.sampleEpisode()
    var game = initSim(config)
    var rows: seq[string]
    while not game.done:
      let seats = game.orderedSeats()
      var decisions: array[Seats, Decision]
      var proposals: array[Seats, JsonNode]
      var records: array[Seats, string]
      for seat in seats:
        let kind = if (seed + game.shift + seat) mod 2 == 0:
          skSteady else: skTaskmaster
        let decision = scriptedAction(game, seat, kind)
        let completion = decisionJson(game, seat, decision)
        let accepted = game.parseReply(seat, completion)
        doAssert accepted.orders == decision.orders
        doAssert accepted.payroll == decision.payroll
        doAssert accepted.run == decision.run
        doAssert accepted.maint == decision.maint
        decisions[seat] = accepted
        proposals[seat] = completion
        let system = systemPrompt(game, seat, wording)
        let user = userPrompt(game, seat, "")
        records[seat] = $(%*{
          "episode_id": "firm-" & variant & "-" & $seed & "-" & $wording.variant & "-" &
            $wording.selectedVariant & "-" & $wording.seed,
          "seed": "firm-" & $seed,
          "decision_id": game.shift * Seats + seat,
          "prompt": [
            {"role": "system", "content": system},
            {"role": "user", "content": user}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "firm",
          "prompt_template": wording.promptMetadata(system, user),
          "action_schema_revision": "firm-reply-v1"
        })
      for seat in seats:
        let decision = decisions[seat]
        let eventStart = game.events.len
        if game.isManager(seat):
          game.applyMemo(seat, decision.orders, decision.payroll,
            decision.split, decision.say, decision.notes, true)
        else:
          game.applyWork(seat, decision.line, decision.run, decision.maint,
            decision.say, decision.notes, true)
        var installed = newJNull()
        for index in eventStart ..< game.events.len:
          let event = game.events[index]
          if event.seat != seat: continue
          case event.kind
          of evMemo:
            installed = %*{"orders": event.orders, "payroll": event.payroll,
              "split": event.split, "directive": event.say, "notes": event.text}
          of evWork:
            installed = %*{"line": event.line, "run": event.run, "maint": event.maint,
              "report": event.say, "notes": event.text}
          else: discard
        doAssert installed.kind == JObject
        if installed == proposals[seat]:
          rows.add(records[seat])
    let results = game.resultsJson()
    doAssert game.shiftsPlayed == config.shifts
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    runs.add(%*{"seed": seed, "shifts": game.shiftsPlayed,
      "decisions": rows.len, "scores": results["scores"],
      "reason": results["reason"], "prompt_selection": wording.selectionMetadata()})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "firm", "variant": variant,
    "source_revision": revision, "teacher": "steady-and-taskmaster",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
