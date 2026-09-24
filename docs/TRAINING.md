# Firm training

The exporter plays ten complete native episodes per certified variant. It
records each seat's exact hosted system and user prompts, plus replies
accepted by the production parser. Every decision in a shift uses the
same pre-shift state. The native simulator applies the manager memo first,
then the four workers' choices and settlement. Train and validation sets
split full episodes by seed.

```sh
nim c -d:release --path:src -o:/tmp/firm-posttrain tools/export_posttrain.nim
/tmp/firm-posttrain /tmp/firm-data 10 standard
```

The other certified variant is `silent-floor`. The output has
`train.jsonl`, `validation.jsonl`, and a manifest with source revision,
seeds, shifts, scores, and row counts. Ten episodes yielded 320/80
train/validation decisions for each variant.

From a Metta checkout with the post-training package installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/firm-data --output /tmp/firm-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes hosted prompts and 45 numeric values
derived from the game's redacted `playerStateJson`. The manager sees the
market board and public floor; workers see their own machine condition
and the public pay rule. Two choices select the published steady and
taskmaster policies. Scores use `score / (abs(score) + 1)` for bounded
(-1, 1) utilities. Post-training above retains arbitrary legal memos,
work plans, and reports.

```sh
nim c -d:release --path:src -o:/tmp/firm-train-bridge tools/train_bridge.nim
python3 tools/test_training.py /tmp/firm-posttrain /tmp/firm-train-bridge
```

From a Metta checkout with the Coworld training stack, pass absolute
bridge and manifest paths to `recipes.external.coworld.train` for native
PufferLib, or `recipes.external.coworld_metta_rl.train` for Metta RL.
Set `players=5` and choose `standard` or `silent-floor`.
