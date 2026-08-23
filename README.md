# Firm

**One manager who sees the market, four workers who see the machines.** A
principal-agent game for the Softmax Coworld platform, on the
[cogame-parley](https://github.com/Metta-AI/cogame-parley) technology stack
(forked from [cogame-bullwhip](https://github.com/Metta-AI/cogame-bullwhip)).

Five cogs run a small factory for eight shifts. The seat-to-role assignment is a
**seeded permutation**, so no policy can choose the office.

- The **Manager** is the only seat that sees the **order board** — how many units
  of product line A and line B the firm can actually sell this shift and next —
  and can do exactly three things a shift: order each machine onto line A or B,
  set the **pay rule** (what percentage of revenue, 0 to 60, goes into the worker
  pool and how that pool splits four ways), and write **one memo** of at most 240
  characters. Everything it decides takes effect **next** shift: it directs blind
  and one shift late.
- Each **Worker** owns one machine, is the only seat that can see its
  **condition** (0..100), and spends a ten-hour shift running a line, maintaining
  the machine, or doing nothing at all.

Running makes about 2 units an hour on a healthy machine and costs it 3
condition an hour; maintenance restores 6; switching lines costs 2 hours of the
shift. A unit sold against demand is worth **$10**, a unit beyond demand is
scrap at **$2**. Workers are paid out of the pool and score their pay minus
**$1.50 an hour of effort**; the manager scores the firm's **profit**.

The arithmetic is the game. At payroll 30 % on an equal split, one running hour
pays a worker `0.25 × 0.30 × $20 = $1.50` — *exactly* what the hour costs it, so
at the default pay rule a worker is precisely indifferent between working and
shirking. The manager has to buy effort, and a worker cut to a 10 % share
rationally goes idle: that is the mutiny, and it is mechanical, not scripted.
Meanwhile `3 × run` of wear against `6 × maint` of repair makes **run 6 /
maint 3** the sustainable pace and **run 10 / maint 0** a machine killed in three
shifts — and a worn machine makes fewer units for the same hours, which from the
office looks exactly like shirking. **That confusion is the benchmark.**

**The game is LLM-driven and a policy is just a prompt.** Every shift the game
server sends each seat's policy prompt plus its role-specific view to Claude —
all five seats as **one parallel batch**, since the shift is simultaneous — and
Claude answers with the memo or the hours. Player containers exist only to
deliver their prompt over the websocket. Two built-in **scripted baselines** —
`steady` (obey, run 6 / maintain 3, report honestly, pay 40 %) and `taskmaster`
(obey, run 10 / maintain 0, everything onto one line, pay 20 %) — play any seat
that registers as scripted, and every seat when no LLM credentials are
available, so episodes (and offline certification) always complete. Both
baselines are **role-complete**: a policy does not know which role it will draw.

Seats play under **anonymous cog aliases** (Sprocket, Gizmo, …): policy display
names never reach the agents' prompts, so nobody can meta-game "that seat is the
champion". The spectator and replay viewers map the aliases back to policy names;
results are reported under policy names.

Scoring: a worker's `score = (Σ pay − Σ toil) / (shifts × 30)`, the manager's
`score = Σ profit / (shifts × 300)`. Higher is better, both roles are on one
ladder, and a competently run firm puts both near **+1**. The episode ends
`complete` after `shifts` shifts (default 8, 4..24) or `deadline` when the
episode clock stops play between shifts.

## Layout

- `src/firm.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/firm/sim.nim` — pure rules: roles and the order board from the seed, the
  shift resolution, memos, hours, wear, sales, payroll, scoring, endings, replay
  derivation; shared by server, tests, and the wasm viewer
- `src/firm/llm.nim` — Claude client (one parallel batch of five per shift) +
  the two scripted baselines
- `src/firm/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/firm_player.nim` — the prompt-delivery player (`PLAYER_PROMPT` /
  `PLAYER_SCRIPTED` env)
- `client/` — shared canvas renderer + global/player/replay pages (the parley
  broadcast chrome around the factory floor)
- `replay-viewer/` — static wasm replay viewer (`?replay=<url>`)
- `tools/build_replay_viewer.sh` — Coworld replay-viewer build hook
- `tools/ci/` — the raw-Docker episode smoke, the headless-browser viewer smoke,
  and the policy set a release uploads
- `scripts/art/` — the nano-banana character sheet and the script that keys,
  splits and pads it into the cog sprites
- `data/` — cog sprites (nano-banana renders of the Softmax cog, one kit per
  role) plus the floor and font borrowed from
  [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (MIT)
- `docs/plans/` — the design note this game was built from

## Board art

`data/cog_manager.png` and `data/cog_worker_{red,blue,green,yellow}.png` are
**nano-banana renders** (`gemini-2.5-flash-image`) of the Softmax cog, one kit
per role: the manager wears a peaked cap and carries a clipboard and a rolled
memo, the four operators wear hard hats and carry wrenches. The roles read at
board scale with every label hidden. The source sheet is committed at
`scripts/art/source/cogs_sheet.png`; regenerate and re-split it with:

```bash
GEMINI_API_KEY=... python3 scripts/art/generate_cog_sheet.py
python3 scripts/art/split_cog_sheet.py
```

`data/soldier_*_front.png` are the coworld-ctf sprites the starter shipped; they
are no longer drawn but remain as the style reference the generator anchors on.

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
nimby --global sync nimby.lock                 # fetch pinned packages
# Generate nim.cfg from your nimby package tree (not committed - the paths are
# machine-specific):
rm -f nim.cfg
for pkg in ~/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg;
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim r --path:src tests/test_sim.nim            # rules tests
nim r -d:release --path:src tests/test_bot.nim # scripted-baseline tests
nim c -d:release -o:bin/firm src/firm.nim
nim c -d:release -o:bin/firm-player src/firm_player.nim
nim c --hints:off -d:emscripten replay-viewer/firm_replay.nim  # wasm viewer

# A full containerised episode (game + five players, results and replay kept):
docker build --platform=linux/amd64 -t coworld-firm:ci .
./tools/ci/docker_smoke.sh coworld-firm:ci
# Export ANTHROPIC_API_KEY for real Claude play; omit it and every seat plays
# the scripted baselines, which is the path certification takes.
```

Coworld packaging (from a metta checkout):

```bash
uv run coworld build --project <this dir> --version 0.1.x
uv run coworld certify <this dir>/dist/coworld_manifest.json
uv run coworld upload-coworld <this dir>/dist/coworld_manifest.json
uv run coworld secret put firm anthropic_api_key <keyfile>   # hosted Claude
```

In this repo that whole chain is the `coworld-release.yml` workflow; `ci.yml` is
the harness (Nim tests debug and release, a raw-Docker episode, and the static
wasm viewer opened in headless chromium against the replay that episode wrote).

## Fielding a policy

```bash
uv run coworld upload-policy <firm image> --name my-firm \
  --run /bin/firm-player \
  --secret-env PLAYER_PROMPT="Your factory strategy here, for BOTH roles."
```

Write the prompt to cover both roles — the seed deals the office. Or field a
scripted baseline: same image, `--env PLAYER_SCRIPTED=steady` or
`--env PLAYER_SCRIPTED=taskmaster`.
