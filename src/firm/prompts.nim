## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "firm-rules-v2"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc managerIntroduction*(selection: PromptSelection, alias: string): string =
  case selection.selectedVariant
  of pvCanonical: "You are " & alias & ", the MANAGER of a small factory with four machines, each run by a different cog. You are the only one who sees the order board. You never set foot on the floor."
  of pvPlain: "You play " & alias & ", the MANAGER of a small factory. Four different cogs each operate one of its four machines. Only you see the order board, and you never visit the floor."
  of pvNumbered: "1. Your identity: " & alias & ", MANAGER. 2. Workplace: a small factory with four machines, each operated by a different cog. 3. Order board access: yours alone. 4. Floor access: you never go there."
  of pvQuestions: "Who are you? " & alias & ", the MANAGER of a small factory. Who runs its four machines? A different cog on each. Who sees the order board? Only you. Do you visit the floor? Never."
  of pvReordered: "Four machines in a small factory each have a different cog operator. You manage that factory as " & alias & ", the MANAGER. You alone see the order board and never set foot on the floor."
  of pvHeldoutBriefing: "Manage the small factory as " & alias & ". Each of its four machines has a different cog operator. As MANAGER, you alone see the order board and never enter the floor."
  of pvHeldoutReference: "Role: MANAGER. Alias: " & alias & ". Factory: small, four machines, a different cog operates each. Order board: visible only to you. Factory floor: never visited by you."
  of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")

proc workerIntroduction*(selection: PromptSelection, alias: string, machine: int): string =
  case selection.selectedVariant
  of pvCanonical: "You are " & alias & ", the operator of MACHINE " & $machine & " of four in a small factory. A manager cog you cannot see runs the office."
  of pvPlain: "You play " & alias & ", operating MACHINE " & $machine & " in a small factory of four machines. An unseen manager cog runs the office."
  of pvNumbered: "1. Your identity: " & alias & ". 2. Your job: operate MACHINE " & $machine & ". 3. Workplace: a small factory with four machines. 4. Office: run by a manager cog you cannot see."
  of pvQuestions: "Who are you? " & alias & ", operator of MACHINE " & $machine & ". Where? A small factory with four machines. Who runs the office? A manager cog you cannot see."
  of pvReordered: "A manager cog you cannot see runs the office of a small four-machine factory. You are " & alias & ", operating MACHINE " & $machine & "."
  of pvHeldoutBriefing: "Operate MACHINE " & $machine & " as " & alias & " in this small factory of four machines. Its office is run by a manager cog hidden from your view."
  of pvHeldoutReference: "Alias: " & alias & ". Assignment: MACHINE " & $machine & ". Factory: small, four machines. Office: run by a manager cog you cannot see."
  of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")
