# Firm training

## Prompt variants and complete text actions

Five training wordings (`canonical`, `plain`, `numbered`, `questions`,
`reordered`) cover both manager and worker roles. `canonical` preserves the
standard-variant messages. Silent-floor now correctly states that worker
reports are disabled. The v2 bank varies identity and role-specific pay/incentives.
Information boundaries, delayed manager orders, effort costs, action grammar,
role assignment, and simulator randomness remain unchanged. `mixed` resolves an explicit nonnegative `promptSeed % 5` once per episode.
`heldout-briefing` and `heldout-reference` are evaluation-only.

The numeric bridge accepts an optional third argument, `text`, for complete
role-specific actions. Reset accepts `promptVariant`, `promptSeed`, and `split`;
held-out training collection is rejected. Every seat sees the same pre-shift
state. Manager demand and worker machine condition remain private to their roles.
The manager's new orders and pay rule still take effect next shift.

## Teacher exports

Export from a clean committed checkout:

```sh
nim c -d:release --path:src -o:/tmp/firm-posttrain tools/export_posttrain.nim
/tmp/firm-posttrain /tmp/firm-examples 10 standard mixed 0
```

Use `silent-floor` for the second certified variant. The exporter plays complete
eight-shift, five-seat games using the existing steady/taskmaster teacher mix.
The original `train.jsonl`, `validation.jsonl`, and `manifest.json` format
is preserved. The original three arguments remain; optional wording and prompt
seed follow the game variant. Mixed selection cycles the five training wordings.

Rows retain exact messages and wording metadata. A row is exported only when
the proposal matches the actual installed memo or work event. The shared action renderer leaves silent-floor worker reports empty, so
teacher exports cover both roles without proposing messages that cannot be sent.
All seats decide before any action is installed.

Seed families exclude variant and wording; multiples of five enter validation.
Output directories are private. Existing paths, fewer than ten games, and
held-out wording exports are rejected.

## Verification

```sh
python3 tools/test_training.py /tmp/firm-posttrain /tmp/firm-train-bridge
```

The existing workflow runs 20 mixed exports, 20 complete wording/private-role
games, and four numeric games. It checks score and observation invariance,
private notes, normalized actions, seed-family separation, and silent-floor
report suppression. These checks establish mechanics and protocol behavior,
not improved learning or resistance to policy collapse.

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
