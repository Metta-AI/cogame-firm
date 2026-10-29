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
seed follow the game variant. Mixed selection cycles the five training wordings
separately within each split. Episode IDs include requested selection, resolved wording, and prompt seed
for matched collections.

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

## Optional native private evidence

`COGAME_SAVE_TRAJECTORY_URI` enables the common private decision JSONL from the
ordinary server. Supply `COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION`, and
`COWORLD_SOURCE_REVISION`; `COWORLD_GAME_IMAGE_DIGEST`, when present, must be an
immutable SHA-256 digest. The private destination must differ from public results
and replay. Capture failures do not change native actions or public artifacts.

The server freezes all five role-private views before requesting any orders. It
records the exact exposed request/entity response bytes (base64), allowlisted
receipt/request headers, settled attempts, actual applied commands, and native
state/event witnesses. Curly discards partial body/header data on transport
errors and may decompress responses: compressed wire bytes are unavailable.
Empty notes/directives remain KEEP commands, distinct from retained notebook or
memo text. Public spectator/replay notebook visibility is unchanged; private
per-seat execution metadata removes foreign notebook event text.

Strict target selection requires unique valid receipt identities, complete
responses, strict scalar JSON without duplicate keys, and supplied field types
and values identical to the installed command. Required fields are manager
orders/payroll or worker line/run. Omitted split defaults to equal shares,
omitted maintenance to zero, and omitted text to the empty KEEP/report command;
explicit nulls are excluded. Silent-floor nonempty reports are excluded even
though native application suppresses them. Normalized native commands remain
recorded as actually applied, without being relabeled as teacher targets.
Invalid scalar evidence is quarantined as original serialized bytes in base64,
with no selected attempt/action and a failed private episode. Numeric parsing,
prompts, clocks and physical rules are unchanged. Native text
inputs reject non-scalar UTF-8 before clipping or state mutation; the existing
model retry/fallback and external-frame rejection paths handle the error. Valid
accents, surrogate pairs and empty KEEP commands retain their behavior.

Native `seed_family` now hashes the actual initialized roles, machines, complete
24-shift demand schedule and active physical rules; requested horizon and report
channel are a separate causal condition. Alias/policy/wording/seed labels cannot
create new worlds. Seeds 9 and 20 share a physical root despite the legacy `%5`
partition. Preserve legacy exports, but regroup their actual initial content
before mixing them with the new schema. Different roots alone do not establish
scientific independence or teacher quality. Local fixture receipts are synthetic
and authorize no model-teacher training.

`tools/test_native_capture.py` runs a complete ordinary loopback HTTP/WS system
fixture against supplied game/player binaries, retaining bounded resource and
health/Pong measurements. `tools/check_native_capture.nim` reconstructs its
private views, prompts, exact HTTP joins, commands and complete native replay.
These checks establish execution and capture, not policy learning.

Policy ownership begins only after a valid prompt, scripted, or external
registration. Startup waits for these registrations within the existing
connection deadline. An unregistered seat uses the shipped steady fallback
without model attempts; late registration affects the next snapshot. A registered
strategy survives disconnection, while replaced sockets cannot mutate the current
registration or external actions. Role assignment, operator wording, and game
rules are unchanged.

New private observations include boolean `policy_registered`. Unregistered
decisions also carry `fallback_reason: "unregistered_policy"`, native origin
`fallback`, no model attempts, and no selected attempt. Registered decisions omit
that reason. The checker validates these invariants before stripping the two
metadata fields to compare the exact native private view. Historical captures
retain their original format and source identities.

```sh
python3 tools/test_policy_registration.py /path/to/firm /tmp/firm-registration-proof
nim c -d:release --path:src -o:/tmp/firm-capture-check tools/check_native_capture.nim
/tmp/firm-capture-check --registration \
  /tmp/firm-registration-proof/missing/config.json \
  /tmp/firm-registration-proof/missing/trajectory.jsonl \
  /tmp/firm-registration-proof/missing/replay.json \
  /tmp/firm-registration-proof/missing/http.json \
  /tmp/firm-registration-proof/operator-prompt.txt
```

The system command uses synthetic loopback replies and runs nine complete
four-shift episodes: missing, late, native, scripted, external, registered and
unregistered disconnects, malformed registration, and socket replacement.
These are zero-provider correctness controls and authorize no teacher targets.
The registration checker also reconstructs prompts, applied events, replay, and
outcomes; run it for each retained case using the same original operator prompt.

Receipt uniqueness covers every received attempt, including HTTP errors and
parser failures. Only syntactically valid 36-character UUIDs enter the private
registry. Reusing one marks the entire private episode failed, so earlier
accepted historical rows cannot enter a complete-episode export. Invalid or
ambiguous IDs remain ineligible; missing transport evidence is never invented.

Scalar validation covers raw response entity bytes, recursively decoded response
envelopes, and decoded completion text, including ignored fields or prefixes
outside the extracted action. Unsafe evidence forces forensic exclusion and a
failed private episode even when native gameplay accepts the extracted command.
Original available bytes and their provenance remain base64/hash witnesses;
public actions and replay do not change. Valid accents and surrogate pairs stay
eligible. The existing private-upload timeout is 60 seconds; it fits the nominal
1200-second episode reserve but does not establish hard process preemption.

The checker retains its completed-positive mode unchanged. Its separate
`--failed-cohort` mode takes the usual five paths followed by a frozen fixture
plan: config, private trajectory, replay, observed HTTP, operator prompt, plan.
It reconstructs the full ordinary eight-shift failed fixture, including the
failed-first/reused-receipt retry, three scalar forensic rows, positive controls,
and all 41 original attempts. Typed SDK whole-file validation and zero complete
units are a separate required check; a failed private cohort is never promoted
because public gameplay completed.

Frozen residual QA plans use the same harness with `--fixture-plan FIXTURE.json`.
Its `--verify-profile` mode reads retained evidence without starting a game;
`--pair-with CONTROL` compares the silent-floor capture-off control. The native
checker's `--profile` mode takes the usual five paths and that fixture plan.
Plans freeze response bytes and the native request generator; actual future
request bytes are recorded before assertions and checked against native views.
The mixed-control private 503 sink retains an offered completed payload for
forensics; a locally readable SDK unit is not successful publication or teacher
admission. A retained notebook-poison fixture exposed an invalid UTF-8 spectator
payload after the first batch; the guard stopped that partial episode before
results, replay or private publication, so its private outcome remains unknown.
The native text boundary now rejects unsafe notes, directives and reports before
mutation. The repaired ordinary eight-shift fixture completes with safe public
frames and results while preserving a failed private episode with no complete
training units.

The checker also exposes `--native-text-boundary` for sixteen native parser/apply
vectors and `--notebook-cohort` for the same six artifact paths used by the
failed-cohort mode. The notebook profile preserves the original response
entities, exercises native retry/fallback, and reconstructs safe controls and
KEEP state. An escaped invalid candidate rejected before application remains a
normal fallback row when its stored evidence is scalar-safe; raw invalid evidence
uses the existing forensic row. Current prospective expectations are one
forensic fallback and one ordinary fallback, rather than two forensic rows.
All sixteen native vectors and the complete notebook fixture pass against the
text-boundary repair. Four preplay external frames are rejected without changing
initial state or events; the ordinary five-prompt roster then completes with 42
HTTP attempts, 38 accepted fixture rows and two fallbacks. The SDK reads all 41
events and admits zero complete units because unsafe evidence fails the private
episode. Synthetic fixture receipts authorize no model-teacher training.
