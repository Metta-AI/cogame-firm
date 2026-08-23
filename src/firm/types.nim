import std/[json, strutils]

const
  Seats* = 5
    ## One Manager and four Workers, always.
  Machines* = 4

type
  FirmError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    shifts*: int          ## shifts of work in the episode
    reports*: bool        ## workers may send the manager a short report
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is silent
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  MachineState* = object
    ## One machine as observed at the start of a shift.
    setup*: string      ## "A" | "B": the line the machine is set to (public)
    order*: string      ## "A" | "B": the line the manager ordered (public)
    condition*: int     ## 0..100 mechanical health; PRIVATE to its worker
    run*: int           ## hours run last shift; private to its worker
    maint*: int         ## hours maintained last shift; private to its worker
    units*: int         ## units delivered last shift (public)
    pay*: float         ## dollars the worker was paid last shift (public)
    toil*: float        ## the worker's own cost of last shift; private

  ShiftResult* = object
    ## One resolved shift, as the settlement recorded it.
    shift*: int
    line*: array[Machines, string]     ## the line each machine actually ran
    run*: array[Machines, int]         ## hours run
    maint*: array[Machines, int]       ## hours maintained
    units*: array[Machines, int]
    condition*: array[Machines, int]   ## after the shift
    soldA*, soldB*: int
    surplusA*, surplusB*: int
    revenue*, pool*, profit*: float
    pay*: array[Machines, float]
    toil*: array[Machines, float]
    obeyed*: array[Machines, bool]
    idle*: array[Machines, bool]

  EventKind* = enum
    evStart = "start"
    evShift = "shift"
    evMemo = "memo"
    evWork = "work"
    evSettle = "settle"
    evEnd = "end"

  GameEvent* = object
    ## Flat by design: the replay language is one JSON object per event and
    ## the viewer re-derives every frame from it.
    kind*: EventKind
    shift*: int            ## shift/memo/work/settle: the shift; end: shifts played
    seat*: int             ## memo/work: the acting seat; -1 otherwise
    worker*: int           ## work: the machine index 0..3; -1 otherwise
    line*: string          ## work: the line the machine ran
    run*, maint*: int      ## work: hours; -1 otherwise
    say*: string           ## memo: the directive; work: the report
    text*: string          ## memo/work: notes after the reply; end: reason;
                           ## shift: the standing directive in force
    scripted*: bool        ## memo/work: decided by a scripted baseline
    demandA*, demandB*: int          ## shift: the order board; -1 otherwise
    machines*: seq[MachineState]     ## shift: the four machines at shift open
    orders*: seq[string]             ## memo: the four lines ordered
    payroll*: int                    ## shift/memo: pool percentage; -1 otherwise
    split*: seq[int]                 ## shift/memo: the four shares
    units*: seq[int]                 ## settle: units per machine
    condition*: seq[int]             ## settle: condition per machine after
    soldA*, soldB*: int              ## settle; -1 otherwise
    surplusA*, surplusB*: int        ## settle; -1 otherwise
    revenue*, pool*, profit*: float  ## settle
    pay*: seq[float]                 ## settle: dollars per machine
    toil*: seq[float]                ## settle: effort cost per machine
    obeyed*: seq[bool]               ## settle: ran the ordered line
    idle*: seq[bool]                 ## settle: ran zero hours

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    shifts: 8,
    reports: true,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 400,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 800,
    llmTimeoutSeconds: 30
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(FirmError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("shifts"):
    config.shifts = node["shifts"].getInt()
  if node.hasKey("reports"):
    config.reports = node["reports"].getBool()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.shifts < 4:
    raise newException(FirmError, "shifts must be at least 4")
  if config.players.len != Seats:
    raise newException(FirmError,
      "firm needs exactly " & $Seats & " players")
