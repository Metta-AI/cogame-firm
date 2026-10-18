# Firm training

## Prompt variants and complete text actions

Five training introductions (`canonical`, `plain`, `numbered`, `questions`,
`reordered`) cover both manager and worker roles. `canonical` preserves the
original messages. Shared rules, role assignment, and simulator randomness stay
fixed. `mixed` resolves an explicit nonnegative `promptSeed % 5` once per episode.
`heldout-briefing` and `heldout-reference` are evaluation-only.

The numeric bridge accepts an optional third argument, `text`, for complete
role-specific actions. Reset accepts `promptVariant`, `promptSeed`, and `split`;
held-out training collection is rejected. Every seat sees the same pre-shift
state. Manager demand and worker machine condition remain private to their roles.
The manager's new orders and pay rule still take effect next shift.

## Reviewed candidate exports

Export from a clean committed checkout:

```sh
nim c -d:release --path:src -o:/tmp/firm-posttrain tools/export_posttrain.nim
/tmp/firm-posttrain /tmp/firm-candidates 10 1 standard canonical 0
```

Use `silent-floor` for the second certified variant. The exporter plays complete
eight-shift, five-seat games using the existing steady/taskmaster teacher mix.
Private `trajectories.jsonl`, `execution.jsonl`, and `manifest.json` retain exact
messages, hashes, source revision, proposed and installed actions, settlement
events, and outcomes. Files use private permissions. Silent-floor suppresses
worker reports; those proposals remain recorded but cannot become accepted labels.
Teacher rows contain no inference request, platform call ID, or log probabilities.

These are candidates, not automatically admitted training data. Convert through
Coworld's `export_complete_episodes`; Metta's independent source-hash review gate
controls label export. Keep each `firm-SEED` family together across variants and
wordings. Existing outputs, fewer than ten games, and held-out exports are rejected.
No automatic train/validation files are emitted.

## Native evidence and verification

Optional `FIRM_HOST_TRACE_PATH`, `FIRM_ATTEMPT_TRACE_DIR`, and
`FIRM_SOURCE_REVISION` record private native evidence. Exact request bodies,
retry messages, raw responses, failures, parsed proposals, installed actions,
and replay event intervals remain separate from public replay metadata.

```sh
python3 tools/test_prompt_games.py /tmp/firm-train-bridge /tmp/original-firm-bridge
python3 tools/test_training.py /tmp/firm-posttrain /tmp/firm-train-bridge
python3 tools/test_native_prompts.py /tmp/firm-game /tmp/firm-player /tmp/firm-native
```

The text panel plays 50 full games and four original numeric comparisons. The
training workflow checks 20 source-export games and four numeric games. The
native panel plays nine published cases with five real player processes and a
reserved closed inference endpoint; `--smoke` runs both canonical variants.
These checks establish execution and provenance, not successful provider inference
or improved learning.

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes hosted prompts and 45 numeric values
derived from the game's redacted `playerStateJson`. The manager sees the
market board and public floor; workers see their own machine condition
and the public pay rule. Two choices select the published steady and
taskmaster policies. Scores use `score / (abs(score) + 1)` for bounded
(-1, 1) utilities. Text collection retains arbitrary legal memos, work plans, and reports.

```sh
nim c -d:release --path:src -o:/tmp/firm-train-bridge tools/train_bridge.nim
python3 tools/test_training.py /tmp/firm-posttrain /tmp/firm-train-bridge
```

From a Metta checkout with the Coworld training stack, pass absolute
bridge and manifest paths to `recipes.external.coworld.train` for native
PufferLib, or `recipes.external.coworld_metta_rl.train` for Metta RL.
Set `players=5` and choose `standard` or `silent-floor`.

Both variants completed 512 Metta RL timesteps with checkpoints and held-out
evaluation. Native PufferLib trained 4,096 CUDA timesteps per variant in
Slurm job 9092, then reloaded checkpoints for held-out seeds 101 and 102.
Both variants scored 1.032 and 0.969 on those seeds. These bounded runs
verify execution, not stronger league play.
