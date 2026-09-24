## Claude-backed decision making for Firm. Each seat's policy is just a
## prompt: the game server composes the seat's role-specific view (the order
## board for the manager, the machine for a worker) plus that seat's prompt
## and asks Claude what it does this shift.
##
## Decisions inside a shift are SIMULTANEOUS by rule, so all five requests go
## out as ONE parallel batch (curly.makeRequests); invalid replies are
## retried as a smaller batch with a hint, and anything still failing falls
## back to the scripted baseline.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bots are also fieldable policies: a player that registers as
## scripted plays one deliberately, LLM or not.

import
  std/[json, math, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## The foil baseline pays as little as the rules allow: below the $1.50/hour
  ## indifference point by construction, so it is not a tuned dial.
  TaskmasterPayroll = 20

type
  ScriptKind* = enum
    skNone = "none"
    skSteady = "steady"
    skTaskmaster = "taskmaster"

  BaselineParams* = object
    ## The `steady` baseline's dials. NOT hand-picked: `tests/test_tuning.nim`
    ## sweeps this grid over seeded all-scripted episodes through this very
    ## `scriptedAction` and asserts `ShippedBaseline` is the argmax; the run
    ## it was taken from is recorded in `docs/baseline-sweep.md`.
    run*, maint*: int            ## the pace on a healthy machine
    nurseRun*, nurseMaint*: int  ## the pace on a machine below `nurseBelow`
    nurseBelow*: int             ## condition at which the machine goes in the shop
    payroll*: int                ## the pool the manager announces

  Decision* = object
    ## One seat's move. The manager fills orders/payroll/split, a worker
    ## fills line/run/maint; `say` is the directive or the report.
    orders*: seq[string]
    payroll*: int
    split*: seq[int]
    line*: string
    run*, maint*: int
    say*: string
    notes*: string      ## "" when the reply carried none
    scripted*: bool     ## this move came from a baseline, not from a reply

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    bedrockEndpoint: string ## bedrock transport: sidecar or public host
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool   ## true once credentials are known-unavailable

const
  # The argmax of the grid sweep in tests/test_tuning.nim, recorded in
  # docs/baseline-sweep.md. run 6 / maint 3 is the sustainable pace (wear
  # 3/hour against repair 6/hour) AND the sweep's unique argmax; payroll 40
  # is the pool at which the manager and the workers score alike, so the
  # weakest seat at the table is highest.
  #
  # The nurse deviates from the design note's "run 4 / maint 6 below 40": on
  # the fallback-recovery family (a wrecked machine handed back to the
  # baseline) the note's drip repair is dominated - a full shift in the shop
  # restores the machine in one shift instead of four, and repairing at 8
  # hours rather than 10 buys the same 100 condition for less toil. Disclosed
  # in docs/baseline-sweep.md and in the r1 fixes note.
  ShippedBaseline* = BaselineParams(
    run: 6, maint: 3,
    nurseRun: 0, nurseMaint: 8, nurseBelow: 70,
    payroll: 40
  )

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "1"/"true"/"yes"/"steady" play the competent
  ## baseline, "taskmaster" the drive-it-into-the-ground one.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "steady": skSteady
  of "taskmaster", "task-master": skTaskmaster
  else: skNone

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "firm llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "firm llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "firm llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "firm llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "firm llm: no LLM credentials; using scripted fallback"

# ---- Formatting -------------------------------------------------------------

proc money*(value: float): string =
  "$" & formatFloat(value, ffDecimal, 2)

proc shareList(split: array[Machines, int]): string =
  var parts: seq[string]
  for worker in 0 ..< Machines:
    parts.add($split[worker])
  parts.join("/")

# ---- Scripted baselines -----------------------------------------------------

proc honestReport(sim: Sim, worker: int): string =
  ## The competent baseline never lies: the report is last shift's actual
  ## numbers, straight off the machine.
  let machine = sim.machines[worker]
  machineLabel(worker) & ": condition " & $machine.condition & ", ran " &
    $machine.run & ", maintained " & $machine.maint & ", " & $machine.units &
    " units."

proc steadyOrders(sim: Sim): seq[string] =
  ## Put as many machines on line A as next shift's board justifies, filling
  ## the A slots with machines already set to A so changeovers are rare.
  let ahead = min(sim.shift + 1, sim.demandA.high)
  let wantA = sim.demandA[ahead]
  let wantB = sim.demandB[ahead]
  let total = max(1, wantA + wantB)
  let countA = clamp(int(round(Machines.float * wantA.float / total.float)),
    0, Machines)
  result = newSeq[string](Machines)
  var assigned = 0
  for worker in 0 ..< Machines:
    if assigned < countA and sim.machines[worker].setup == "A":
      result[worker] = "A"
      inc assigned
  for worker in 0 ..< Machines:
    if result[worker].len == 0:
      if assigned < countA:
        result[worker] = "A"
        inc assigned
      else:
        result[worker] = "B"

proc steadySplit(sim: Sim): seq[int] =
  ## Reward output: last shift's units by largest remainder, equal shares
  ## before anything has been made.
  var units: seq[float]
  var total = 0.0
  for worker in 0 ..< Machines:
    units.add(sim.machines[worker].units.float)
    total += sim.machines[worker].units.float
  let shares = if total <= 0.0: normalizeSplit(@[]) else: normalizeSplit(units)
  for worker in 0 ..< Machines:
    result.add(shares[worker])

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind,
    params: BaselineParams = ShippedBaseline): Decision =
  ## Rule-based baseline for `seat`, whichever role the seed dealt it.
  ## Always legal by construction; never writes notes. `params` is the tuning
  ## harness's handle on the `steady` dials — production always takes the
  ## default, `ShippedBaseline`.
  let effective = if kind == skNone: skSteady else: kind
  ## Provenance rides on the decision itself: a seat that fell back mid
  ## episode must be recorded as scripted in the replay, not just on stdout.
  result.scripted = true
  if sim.isManager(seat):
    let ahead = min(sim.shift + 1, sim.demandA.high)
    case effective
    of skTaskmaster:
      ## Everything onto the bigger book, pay as little as allowed.
      let line = if sim.demandB[ahead] > sim.demandA[ahead]: "B" else: "A"
      result.orders = @[line, line, line, line]
      result.payroll = TaskmasterPayroll
      result.split = @[25, 25, 25, 25]
      result.say = "All four machines on line " & line &
        ". Ten hours running. Maintenance is not output."
    else:
      result.orders = steadyOrders(sim)
      result.payroll = params.payroll
      result.split = steadySplit(sim)
      var onA: seq[string]
      var onB: seq[string]
      for worker in 0 ..< Machines:
        if result.orders[worker] == "A": onA.add($(worker + 1))
        else: onB.add($(worker + 1))
      var shares: seq[string]
      for share in result.split:
        shares.add($share)
      result.say = "Shift " & $(sim.shift + 1) & ": " &
        (if onA.len > 0: "machines " & onA.join(",") & " on line A"
         else: "no machine on line A") & ", " &
        (if onB.len > 0: "machine" & (if onB.len > 1: "s " else: " ") &
          onB.join(",") & " on line B" else: "none on line B") &
        ". Pool is " & $result.payroll & "% of revenue; shares " &
        shares.join("/") & ". Six hours running, three on maintenance."
  else:
    let worker = sim.workerIndex[seat]
    result.line = sim.machines[worker].order
    case effective
    of skTaskmaster:
      result.run = ShiftHours
      result.maint = 0
      result.say = machineLabel(worker) & ": ten hours, no stoppages."
    else:
      if sim.machines[worker].condition < params.nurseBelow:
        result.run = params.nurseRun
        result.maint = params.nurseMaint
      else:
        result.run = params.run
        result.maint = params.maint
      result.say = honestReport(sim, worker)

# ---- Prompt building --------------------------------------------------------

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc systemPrompt*(sim: Sim, seat: int): string =
  let me = sim.names[seat]
  const JsonClause = """

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no
analysis, no explanation, no markdown fences, no text before or after
the object. Your reply must begin with the character { and end with }."""
  if sim.isManager(seat):
    result = "You are " & me & ", the MANAGER of a small factory with four " &
      "machines, each run by a different cog. You are the only one who sees " &
      "the order board. You never set foot on the floor." & """

Rules:
- Every shift you do exactly three things: order each machine onto product
  line A or B, set the PAY RULE (what percentage of revenue goes into the
  worker pool, 0 to 60, and how that pool is split four ways), and write one
  memo of at most 240 characters. Everything you decide this shift takes
  effect NEXT shift - the workers read your memo one shift late.
- The board: line A and line B each have a number of units the firm can sell
  this shift, and you can also see next shift's numbers. A unit sold against
  demand is worth $10. A unit made beyond demand is scrap and fetches $2.
  Nothing else earns anything.
- A healthy machine makes about 12 units in a shift. Switching a machine to
  the other line costs it 2 hours of that shift.
- You see how many units each machine delivered and what each worker was
  paid. You do NOT see how the worker spent the shift, and you do NOT see the
  condition of any machine. A machine can be worn out, and a worn machine
  makes fewer units for the same hours. It looks exactly like shirking from
  where you sit.
- The workers are paid out of the pool you set and are NOT paid for effort. A
  worker whose share is small has little reason to work hard. Your SCORE is
  the firm's PROFIT - revenue minus the wages you paid - and nothing else.
- Workers may send you a short report each shift. They are not obliged to be
  honest.
- Your notes are private to you and fed back to you every shift.""" &
      JsonClause
  else:
    let worker = sim.workerIndex[seat]
    result = "You are " & me & ", the operator of MACHINE " & $(worker + 1) &
      " of four in a small factory. A manager cog you cannot see runs the " &
      "office." & """

Rules:
- Each shift is 10 hours. You choose the product line your machine runs (A or
  B), how many hours you RUN it, and how many hours you MAINTAIN it. Running
  and maintaining together cannot exceed 10; the rest is idle time and costs
  you nothing.
- Running makes units: about 2 units an hour on a machine in perfect
  condition, less as the machine wears. Every hour of running costs the
  machine 3 condition; every hour of maintenance restores 6. Condition runs 0
  to 100 and starts at 100. Only YOU can see your machine's condition - the
  manager cannot.
- Switching to the other line costs you 2 of your running hours this shift.
- You are paid a share of a pool: the manager announces what percentage of
  the firm's revenue goes into the pool and how it is split between the four
  machines. You are NOT paid for hours. Every hour you spend, running or
  maintaining, costs you $1.50 of effort. Your SCORE is your pay minus that
  effort cost, added up over the episode. Nothing else scores you.
- You never see the order board. Only the manager knows how many units of
  each line the firm can actually sell; units the firm cannot sell are nearly
  worthless, so an order to run the wrong line pays you almost nothing.
- You may send the manager one short report each shift (max 120 characters).
  It is not binding and nobody checks it against the truth.
- You may follow your orders, ignore them, or do nothing at all. Nothing
  forces you.
- Your notes are private to you and fed back to you every shift.""" &
      JsonClause

proc floorTable(sim: Sim): string =
  var lines: seq[string]
  lines.add("machine | operator | set to | ordered | units | paid | share")
  for worker in 0 ..< Machines:
    let machine = sim.machines[worker]
    lines.add($(worker + 1) & " | " & sim.names[sim.workerSeat[worker]] &
      " | " & machine.setup & " | " & machine.order & " | " & $machine.units &
      " | " & money(machine.pay) & " | " & $sim.split[worker] & "%")
  lines.join("\n")

proc ledgerTable(sim: Sim): string =
  var lines: seq[string]
  lines.add("shift | A wanted | B wanted | A made | B made | sold | scrap | " &
    "revenue | wages | profit")
  for record in sim.history:
    let index = record.shift
    lines.add($index & " | " & $sim.board[index].a & " | " &
      $sim.board[index].b & " | " & $(record.soldA + record.surplusA) &
      " | " & $(record.soldB + record.surplusB) & " | " &
      $(record.soldA + record.soldB) & " | " &
      $(record.surplusA + record.surplusB) & " | " & money(record.revenue) &
      " | " & money(record.pool) & " | " & money(record.profit))
  if sim.history.len == 0:
    lines.add("(no shift has been settled yet)")
  lines.join("\n")

proc workerHistoryTable(sim: Sim, worker: int): string =
  var lines: seq[string]
  lines.add("shift | line | ran | maintained | condition after | units | " &
    "paid | effort | net")
  var running = 0.0
  for record in sim.history:
    running += record.pay[worker] - record.toil[worker]
    lines.add($record.shift & " | " & record.line[worker] & " | " &
      $record.run[worker] & "h | " & $record.maint[worker] & "h | " &
      $record.condition[worker] & " | " & $record.units[worker] & " | " &
      money(record.pay[worker]) & " | " & money(record.toil[worker]) & " | " &
      money(running))
  if sim.history.len == 0:
    lines.add("(this is your first shift)")
  lines.join("\n")

proc floorBoard(sim: Sim): string =
  ## What every worker may see: the shop floor is public, condition is not.
  var lines: seq[string]
  lines.add("machine | operator | set to | ordered | units")
  for worker in 0 ..< Machines:
    let machine = sim.machines[worker]
    lines.add($(worker + 1) & " | " & sim.names[sim.workerSeat[worker]] &
      " | " & machine.setup & " | " & machine.order & " | " & $machine.units)
  lines.join("\n")

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let shown = min(sim.shift, sim.demandA.high)
  let ahead = min(sim.shift + 1, sim.demandA.high)
  if sim.isManager(seat):
    result.add("Shift " & $sim.shift & " of " & $sim.config.shifts & ".\n\n")
    result.add("THE BOARD: this shift line A wants " & $sim.demandA[shown] &
      ", line B wants " & $sim.demandB[shown] & "; next shift line A wants " &
      $sim.demandA[ahead] & ", line B wants " & $sim.demandB[ahead] &
      ". Sold units pay $10, scrap $2.\n\n")
    result.add("THE FLOOR:\n" & sim.floorTable() & "\n\n")
    result.add("HISTORY:\n" & sim.ledgerTable() & "\n\n")
    result.add("THE PAY RULE IN FORCE: pool " & $sim.payroll &
      "% of revenue; shares " & shareList(sim.split) & ".\n\n")
    var heard: seq[string]
    if sim.config.reports:
      for worker in 0 ..< Machines:
        if sim.heardReports[worker].len > 0:
          heard.add(sim.names[sim.workerSeat[worker]] & " (" &
            machineLabel(worker) & "): \"" & sim.heardReports[worker] & "\"")
    result.add("REPORTS FROM LAST SHIFT:\n" &
      (if heard.len > 0: heard.join("\n") else: "(none)") & "\n\n")
    result.add("YOUR NOTES FROM EARLIER SHIFTS:\n" &
      (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
    result.add(operatorBlock(prompt))
    result.add("Reply with ONLY {\"orders\": [\"A\",\"A\",\"A\",\"B\"], " &
      "\"payroll\": 40, \"split\": [25,25,25,25], \"directive\": \"…\", " &
      "\"notes\": \"…\"} — orders is the line for machines 1,2,3,4 in that " &
      "order; payroll is a whole number 0 to " & $MaxPayrollPercent &
      "; split is four non-negative numbers (they are renormalized to sum " &
      "to 100); directive at most " & $MaxDirectiveLen &
      " characters (or \"\" to leave the standing memo); notes at most " &
      $MaxNotesLen & " characters.")
  else:
    let worker = sim.workerIndex[seat]
    let machine = sim.machines[worker]
    result.add("Shift " & $sim.shift & " of " & $sim.config.shifts &
      ". You run MACHINE " & $(worker + 1) & ".\n\n")
    result.add("YOUR MACHINE: set to line " & machine.setup & ", condition " &
      $machine.condition & ", ")
    if sim.history.len == 0:
      result.add("this is your first shift.\n\n")
    else:
      result.add("last shift you ran " & $machine.run &
        "h and maintained " & $machine.maint & "h and delivered " &
        $machine.units & " units and were paid " & money(machine.pay) &
        " for " & money(machine.toil) & " of effort.\n\n")
    result.add("YOUR ORDERS THIS SHIFT: run line " & machine.order & ".\n\n")
    result.add("THE MEMO: \"" & sim.directive & "\"\n\n")
    var shares: seq[string]
    for other in 0 ..< Machines:
      shares.add("machine " & $(other + 1) & ": " & $sim.split[other] & "%")
    result.add("THE PAY RULE THIS SHIFT: pool " & $sim.payroll &
      "% of revenue; shares — " & shares.join(", ") & ".\n\n")
    result.add("YOUR HISTORY:\n" & sim.workerHistoryTable(worker) & "\n\n")
    result.add("THE FLOOR LAST SHIFT:\n" & sim.floorBoard() & "\n\n")
    result.add("YOUR NOTES FROM EARLIER SHIFTS:\n" &
      (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
    result.add(operatorBlock(prompt))
    result.add("Reply with ONLY {\"line\": \"A\", \"run\": 6, \"maint\": 3" &
      (if sim.config.reports: ", \"report\": \"…\"" else: "") &
      ", \"notes\": \"…\"} — line is \"A\" or \"B\"; run and maint are " &
      "whole numbers of hours, 0 to " & $ShiftHours &
      ", and together at most " & $ShiftHours &
      (if sim.config.reports: "; report at most " & $MaxReportLen &
        " characters (or \"\")" else: "") &
      "; notes at most " & $MaxNotesLen & " characters.")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model
    ## sent instead of JSON (prose, a refusal, a cut-off analysis...).
    var head = text.strip()
    ## Cut on a RUNE boundary: these messages are echoed to the container log
    ## and half a multi-byte character there is unreadable.
    if head.runeLen > 160:
      head = head.runeSubStr(0, 160) & "..."
    raise newException(FirmError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one batched reply, or a FirmError describing why there is
  ## none. Auth failures disable the client; model-access and throttle
  ## failures rotate the Bedrock model for the next batch.
  if error.len > 0:
    raise newException(FirmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body.runeSubStr(0, 400)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(FirmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(FirmError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.runeSubStr(0, 300)
    discard client.tryNextBedrockModel("throttled")
    raise newException(FirmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(FirmError, "anthropic error " & $response.code &
      ": " & response.body.runeSubStr(0, 300))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(FirmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(FirmError, "reply cut off at max_tokens before " &
      "any JSON: " & result.runeSubStr(0, 160).replace("\n", " "))

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked, so a
  ## multi-byte character can never be sliced in half into the replay JSON.
  result = text.strip().replace("\r", " ").replace("\n", " ")
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc wholeNumber(node: JsonNode, name: string): int =
  ## An integer, a numeric string, or a float (rounded). Raises otherwise.
  if node.isNil or node.kind == JNull:
    raise newException(FirmError, "no " & name & " in response")
  case node.kind
  of JInt: node.getInt()
  of JFloat: int(round(node.getFloat()))
  of JString:
    let text = node.getStr().strip()
    try:
      int(round(parseFloat(text)))
    except ValueError:
      raise newException(FirmError, name & " is not a number: " & text)
  else:
    raise newException(FirmError, name & " must be a number: " & $node)

proc parseManagerReply*(sim: Sim, payload: JsonNode): Decision =
  ## Tolerant by design: an unusable ORDER keeps the machine's current
  ## order and an unusable SPLIT falls back to an equal one, but a missing
  ## or out-of-range PAYROLL is invalid — the pay rule is the manager's one
  ## enforceable instrument and guessing it would be worse than a retry.
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.say = cleanText(payload{"directive"}.getStr(), MaxDirectiveLen)
  result.orders = newSeq[string](Machines)
  let ordersNode = payload{"orders"}
  for worker in 0 ..< Machines:
    var line = ""
    if not ordersNode.isNil and ordersNode.kind == JArray and
        ordersNode.len == Machines:
      line = normalizeLine(ordersNode[worker].getStr())
    if line.len == 0:
      line = sim.machines[worker].order
    result.orders[worker] = line
  let payroll = wholeNumber(payload{"payroll"}, "payroll")
  if payroll < 0 or payroll > MaxPayrollPercent:
    raise newException(FirmError,
      "payroll must be 0.." & $MaxPayrollPercent & ": " & $payroll)
  result.payroll = payroll
  let splitNode = payload{"split"}
  if splitNode.isNil or splitNode.kind == JNull:
    result.split = @[25, 25, 25, 25]
  else:
    if splitNode.kind != JArray or splitNode.len != Machines:
      raise newException(FirmError,
        "split must be " & $Machines & " numbers: " & $splitNode)
    var shares: seq[float]
    for index in 0 ..< Machines:
      let share = wholeNumber(splitNode[index], "split").float
      if share < 0.0:
        raise newException(FirmError, "a share cannot be negative")
      shares.add(share)
    let normalized = normalizeSplit(shares)
    result.split = @[]
    for worker in 0 ..< Machines:
      result.split.add(normalized[worker])

proc parseWorkerReply*(sim: Sim, seat: int, payload: JsonNode): Decision =
  ## Tolerant on the LINE (an unknown line keeps the machine where it is),
  ## strict on the HOURS: they are the whole decision.
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.say = cleanText(payload{"report"}.getStr(), MaxReportLen)
  result.line = normalizeLine(payload{"line"}.getStr())
  if result.line.len == 0:
    result.line = sim.machines[sim.workerIndex[seat]].setup
  let run = wholeNumber(payload{"run"}, "run")
  if run < 0 or run > ShiftHours:
    raise newException(FirmError,
      "run must be 0.." & $ShiftHours & ": " & $run)
  result.run = run
  let maintNode = payload{"maint"}
  result.maint =
    if maintNode.isNil or maintNode.kind == JNull: 0
    else: wholeNumber(maintNode, "maint")
  if result.maint < 0 or result.maint > ShiftHours:
    raise newException(FirmError,
      "maint must be 0.." & $ShiftHours & ": " & $result.maint)
  if result.run + result.maint > ShiftHours:
    raise newException(FirmError, "a shift is only " & $ShiftHours &
      " hours: " & $result.run & " + " & $result.maint)

proc parseReply*(sim: Sim, seat: int, payload: JsonNode): Decision =
  if sim.isManager(seat):
    parseManagerReply(sim, payload)
  else:
    parseWorkerReply(sim, seat, payload)

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Decision] =
  ## One decision per seat in `seats`, in order — the manager's and the four
  ## workers' as ONE parallel batch, because their decisions are
  ## simultaneous by rule. Never raises: any failure falls back to the
  ## scripted baseline so the episode always advances.
  ## `prompts` and `scripted` are indexed by SEAT.
  result = newSeq[Decision](seats.len)
  var open: seq[int]     ## indexes into `seats` still undecided
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result[index] = scriptedAction(sim, seat, kind)
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add("\nYour previous reply was invalid. Respond with ONLY " &
          "the requested JSON object.")
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        let decision = parseReply(sim, seat, extractJsonObject(text))
        ## Reject illegal replies here so the retry carries the hint.
        var probe = sim
        if sim.isManager(seat):
          probe.applyMemo(seat, decision.orders, decision.payroll,
            decision.split, decision.say, decision.notes, false)
        else:
          probe.applyWork(seat, decision.line, decision.run, decision.maint,
            decision.say, decision.notes, false)
        result[index] = decision
      except CatchableError as error:
        echo "firm llm: seat ", seat, " attempt ", attempt, " failed: ",
          error.msg
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "firm llm: seat ", seat, " falling back to scripted decision"
    result[index] = scriptedAction(sim, seat, skSteady)
