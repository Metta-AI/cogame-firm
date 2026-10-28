"""One complete unchanged Firm episode; loopback fixtures never authorize teachers."""

import argparse
import base64
import hashlib
import http.server
import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time
import urllib.request
import uuid
from pathlib import Path

from websockets.exceptions import ConnectionClosed
from websockets.sync.client import connect


def verify_profile_artifacts(output, plan_path, pair_with=None):
    """Read retained fixture evidence through the maintained SDK; never starts a game."""
    from coworld.decision_trajectory import complete_episodes, read_trajectory_jsonl

    spec = json.loads(plan_path.read_text())
    mixed = spec["profile"] == "mixed-control-transport-publication"
    expected = spec.get("expected_HTTP_each", spec.get("expected_HTTP"))
    load_lines = lambda path: [json.loads(x) for x in path.read_text().splitlines()]
    calls = load_lines(output / "observed-http.jsonl")
    arrivals = load_lines(output / "received-http.jsonl")
    offers = load_lines(output / "offered-http.jsonl")
    assert len(calls) == len(arrivals) == len(offers) == expected
    assert sorted(x["body_b64"] for x in arrivals) == sorted(
        x["request_body_b64"] for x in calls
    )
    by = {(x["shift"], x["slot"], x["native_attempt_zero_based"]): x for x in calls}
    assert len(by) == len(calls)
    for cell in spec["matrix"]:
        call = by[(cell["shift"], cell["seat"], cell["native_attempt_zero_based"])]
        for key in ["response_body_b64", "call_id", "request_id"]:
            assert call[key] == cell[key]
        assert call["response_status"] == cell["http_status"]
        assert call["response_complete_offered"] == (cell["delivery"] == "complete")
    results = json.loads((output / "results.json").read_text())
    assert results["reason"] == "complete" and results["shifts"] == 8
    trace_path = output / (
        "offered-private-trajectory.jsonl" if mixed else "private-trajectory.jsonl"
    )
    raw = load_lines(trace_path)
    typed = list(read_trajectory_jsonl(trace_path))
    units = list(complete_episodes(typed))
    assert (
        len(raw) == len(typed) == 41
        and len(units) == 1
        and raw[-1]["status"] == "completed"
    )
    attempts = 0
    statuses = {}
    for row in raw[:-1]:
        statuses[row["action_status"]] = statuses.get(row["action_status"], 0) + 1
        shift = row["observation"]["shift"]
        seat = int(row["seat"])
        for index, attempt in enumerate(row["attempts"]):
            attempts += 1
            wire = by[(shift, seat, index)]
            requested = row["observation"]["native_requests"][index]
            assert requested["body_b64"] == wire["request_body_b64"]
            assert attempt["request"] == wire["request"]
            for other in range(5):
                if other != seat:
                    assert (
                        f"PRIVATE_FIRM_NOTE_SLOT_{other}"
                        not in attempt["request"]["messages"][0]["content"]
                    )
            assert (
                "EXTERNAL_PRIVATE_0" not in attempt["request"]["messages"][0]["content"]
            )
            if wire["delivery"] == "partial_timeout":
                assert (
                    attempt["response_complete"] is False
                    and attempt["response_reader_joined"] is True
                )
                assert all(
                    attempt[k] is None
                    for k in [
                        "http_status",
                        "response_body_b64",
                        "response_headers",
                        "platform_call_id",
                        "provider_request_id",
                    ]
                )
                assert attempt["latency_ms"] >= 29_000
                assert "transport_gap" in requested
            else:
                assert attempt["response_body_b64"] == wire["response_body_b64"]
                assert attempt["platform_call_id"] == wire["call_id"]
                assert attempt["provider_request_id"] == wire["request_id"]
    assert attempts == expected
    if mixed:
        assert statuses == {"accepted": 19, "missing": 16, "fallback": 5}
        assert not (output / "private-trajectory.jsonl").exists()
        delivery = json.loads((output / "private-delivery.json").read_text())
        assert delivery["method"] == "PUT" and delivery["path"] == "/private-trajectory"
        assert (
            delivery["response_status"] == 503
            and delivery["publication_success"] is False
        )
        assert hashlib.sha256(trace_path.read_bytes()).hexdigest() == delivery["sha256"]
        assert (
            "private capture publication failed:" in (output / "game.log").read_text()
        )
        assert len(load_lines(output / "external-actions.jsonl")) == 8
        prefixes = load_lines(output / "partial-http-prefixes.jsonl")
        assert len(prefixes) == 1 and prefixes[0]["full_body_sent"] is False
        timeout = next(c for c in spec["matrix"] if c["delivery"] == "partial_timeout")
        assert (
            base64.b64decode(prefixes[0]["offered_prefix_b64"])
            == base64.b64decode(timeout["response_body_b64"])[
                : timeout["partial_prefix_bytes"]
            ]
        )
    else:
        assert statuses == {
            "accepted": spec["strict_accepted_expected"],
            "rejected": spec["strict_excluded_expected"],
        }
        assert pair_with is not None, (
            "silent ON verification requires the frozen OFF control"
        )
        for name in ["config.json", "results.json", "replay.json"]:
            assert (output / name).read_bytes() == (pair_with / name).read_bytes()
        other = {
            (x["shift"], x["slot"], x["native_attempt_zero_based"]): x
            for x in load_lines(pair_with / "observed-http.jsonl")
        }
        assert other.keys() == by.keys()
        for key, call in by.items():
            for field in [
                "request_body_b64",
                "safe_request_headers",
                "response_body_b64",
                "response_status",
                "call_id",
                "request_id",
            ]:
                assert call[field] == other[key][field]
        assert not (pair_with / "private-trajectory.jsonl").exists()
    summary = {
        "status": "PASS",
        "profile": spec["profile"],
        "typed_events": len(typed),
        "local_complete_units": len(units),
        "HTTP": attempts,
        "action_status_counts": statuses,
        "publication_success": not mixed,
        "teacher_authorized_rows": 0,
        "provider_calls": 0,
        "partial_offered_prefix_is_not_native_received_evidence": mixed,
        "native_simulation_reconstruction_required_separately": True,
    }
    with (output / "profile-SDK-byte-joins.json").open("x") as evidence:
        evidence.write(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("game", type=Path)
parser.add_argument("player", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--capture", action="store_true")
parser.add_argument(
    "--wall-limit-seconds",
    type=float,
    default=600,
    help="Owned QA guard only; native clocks unchanged (max600)",
)
parser.add_argument(
    "--fixture-plan",
    type=Path,
    help="Frozen local silent/mixed fixture JSON; no providers",
)
parser.add_argument(
    "--verify-profile",
    action="store_true",
    help="Read retained artifacts only; no game starts",
)
parser.add_argument(
    "--pair-with",
    type=Path,
    help="Retained silent capture-OFF control for offline parity",
)
args = parser.parse_args()
if args.verify_profile:
    assert args.fixture_plan is not None
    verify_profile_artifacts(args.output.resolve(), args.fixture_plan, args.pair_with)
    raise SystemExit(0)
assert 0 < args.wall_limit_seconds <= 600
GAME = args.game.resolve()
PLAYER = args.player.resolve()
OUT = args.output.resolve()
OUT.mkdir(mode=0o700, parents=True, exist_ok=False)
os.umask(0o077)
ROOT = Path.cwd()
profile = json.loads(args.fixture_plan.read_text()) if args.fixture_plan else None
profile_cases = {}
profile_counts = {}
received_count = 0
http_limit = (
    profile.get("source_bound_HTTP_each", profile.get("source_bound_HTTP"))
    if profile
    else 80
)
if profile:
    assert profile["profile"] in [
        "silent-strict-pair",
        "mixed-control-transport-publication",
    ]
    assert (
        hashlib.sha256(GAME.read_bytes()).hexdigest()
        == profile["runtime_binary_sha256"]
    )
    for name, expected in profile["runtime_source_sha256"].items():
        assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == expected, name
    for cell in profile["matrix"]:
        key = (cell["shift"], cell["seat"], cell["native_attempt_zero_based"])
        assert key not in profile_cases
        profile_cases[key] = cell
        assert (
            hashlib.sha256(
                (args.fixture_plan.parent / cell["response_file"]).read_bytes()
            ).hexdigest()
            == cell["response_sha256"]
        )
    (OUT / "frozen-fixture-plan.json").write_bytes(args.fixture_plan.read_bytes())
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
assert GAME.is_file() and PLAYER.is_file()
operator_prompt_match = re.search(
    r'const DefaultPrompt = """\n(.*?)"""',
    Path("src/firm_player.nim").read_text(),
    re.DOTALL,
)
assert operator_prompt_match is not None
operator_prompt = operator_prompt_match[1]
(OUT / "operator-prompt.txt").write_text(operator_prompt)
source = {
    str(p): hashlib.sha256(p.read_bytes()).hexdigest()
    for p in list(Path("src").rglob("*.nim")) + [Path(__file__)]
}
(OUT / "source-bindings.json").write_text(json.dumps(source, indent=2) + "\n")
(OUT / "binary-identities.json").write_text(
    json.dumps(
        {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in [GAME, PLAYER]},
        indent=2,
    )
    + "\n"
)
START = time.monotonic()
stop = threading.Event()
ready = threading.Event()
external_ready = threading.Event()
external_threads = []
failures = []
closures = []
calls = []
lock = threading.Lock()
processes = []
logs = []


def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


game_port = port()
manager = 3  # Independently retained native initialization seed9; checker rederives actual roles.


def retain_private(request):
    """The local sink preserves offered bytes, then refuses publication with503."""
    size = int(request.headers["Content-Length"])
    assert size <= 12 * 2**20, "private offer exceeds native12MiB guard"
    payload = request.rfile.read(size)
    with (OUT / "offered-private-trajectory.jsonl").open("xb") as evidence:
        evidence.write(payload)
    (OUT / "private-delivery.json").write_text(
        json.dumps(
            {
                "method": request.command,
                "path": request.path,
                "bytes": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
                "response_status": 503,
                "publication_success": False,
                "fixture_only": True,
            }
        )
        + "\n"
    )
    assert request.path == "/private-trajectory" and request.command == "PUT"
    request.send_response(503)
    request.send_header("Content-Length", "0")
    request.end_headers()


def serve_profile(request, raw, began):
    body = json.loads(raw)
    seat = int(request.headers["X-Coworld-Player-Slot"])
    shift_match = re.match(r"Shift (\d+) of 8\.", body["messages"][0]["content"])
    assert shift_match is not None
    shift = int(shift_match[1])
    assert request.path == "/v1/messages" and 0 <= seat < 5 and 0 <= shift < 8
    assert body["model"] == "anthropic/claude-haiku-4.5" and body["max_tokens"] == 800
    assert not any(
        k.lower() in {"authorization", "x-api-key", "cookie"} for k in request.headers
    )
    with lock:
        attempt = profile_counts.get((shift, seat), 0)
        profile_counts[(shift, seat)] = attempt + 1
        assert (shift, seat, attempt) in profile_cases, (
            "unplanned request: preserve and stop"
        )
        case = profile_cases[(shift, seat, attempt)]
        reply = (args.fixture_plan.parent / case["response_file"]).read_bytes()
        assert hashlib.sha256(reply).hexdigest() == case["response_sha256"]
        call = {
            "observed_HTTP_index": len(calls),
            "slot": seat,
            "shift": shift,
            "native_attempt_zero_based": attempt,
            "case": case["case"],
            "request_started_monotonic": began,
            "request": body,
            "request_body_b64": base64.b64encode(raw).decode(),
            "safe_request_headers": {
                n: v
                for n, v in request.headers.items()
                if n.lower()
                in {"content-type", "anthropic-version", "x-coworld-player-slot"}
            },
            "response_body_b64": case["response_body_b64"],
            "response_status": case["http_status"],
            "call_id": case["call_id"],
            "request_id": case["request_id"],
            "delivery": case["delivery"],
            "fixture_only": True,
        }
        calls.append(call)
        with (OUT / "offered-http.jsonl").open("a") as evidence:
            evidence.write(json.dumps(call) + "\n")
    request.send_response(case["http_status"])
    request.send_header("Content-Type", "application/json")
    request.send_header("Content-Length", str(len(reply)))
    request.send_header("X-Softmax-Llm-Call-Id", case["call_id"])
    request.send_header("request-id", case["request_id"])
    request.end_headers()
    if case["delivery"] == "partial_timeout":
        prefix = reply[: case["partial_prefix_bytes"]]
        request.wfile.write(prefix)
        request.wfile.flush()
        with lock, (OUT / "partial-http-prefixes.jsonl").open("a") as evidence:
            evidence.write(
                json.dumps(
                    {
                        "slot": seat,
                        "shift": shift,
                        "attempt": attempt,
                        "offered_prefix_b64": base64.b64encode(prefix).decode(),
                        "prefix_flushed_monotonic": time.monotonic(),
                        "full_body_sent": False,
                        "native_receipt_or_partial_body_not_claimed": True,
                    }
                )
                + "\n"
            )
        time.sleep(case["partial_hold_seconds"])
        call["response_complete_offered"] = False
    else:
        time.sleep(0.05)
        request.wfile.write(reply)
        request.wfile.flush()
        call["response_complete_offered"] = True
    call["response_finished_monotonic"] = time.monotonic()
    with lock, (OUT / "observed-http.jsonl").open("a") as evidence:
        evidence.write(json.dumps(call) + "\n")


def external_player(seat):
    assert profile is not None
    try:
        with connect(
            f"ws://127.0.0.1:{game_port}/player?slot={seat}&token=fixture-firm-token-{seat}",
            proxy=None,
            close_timeout=2,
            max_size=2**20,
            max_queue=1024,
        ) as player:
            welcome = json.loads(player.recv(timeout=5))
            assert welcome["type"] == "welcome" and welcome["slot"] == seat
            player.send(
                json.dumps(
                    {
                        "type": "prompt",
                        "prompt": "Frozen local external QA",
                        "scripted": "steady",
                    }
                )
            )
            player.send(json.dumps({"type": "register", "control": "external"}))
            external_ready.set()
            while not stop.is_set():
                try:
                    raw = player.recv(timeout=0.25)
                except TimeoutError:
                    continue
                frame = json.loads(raw)
                with (OUT / "external-frames.jsonl").open("a") as evidence:
                    evidence.write(json.dumps(frame) + "\n")
                if frame["type"] == "final":
                    break
                if frame["type"] != "observation":
                    continue
                shift = frame["observation"]["shift"]
                cells = [
                    x
                    for x in profile["external_actions"]
                    if x["shift"] == shift and x["seat"] == seat
                ]
                assert len(cells) == 1
                action = {
                    "type": "action",
                    "id": frame["id"],
                    "action": cells[0]["action"],
                }
                with (OUT / "external-actions.jsonl").open("a") as evidence:
                    evidence.write(json.dumps(action) + "\n")
                player.send(json.dumps(action))
    except ConnectionClosed as error:
        closures.append(
            {
                "external_slot": seat,
                "exception": repr(error),
                "elapsed_seconds": time.monotonic() - START,
            }
        )
    except BaseException as error:  # noqa: BLE001 - preserve owned fixture failure
        failures.append(repr(error))
        external_ready.set()


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        global received_count
        began = time.monotonic()
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        # Preserve received bytes BEFORE decoding or asserting coordinates/schema.
        with lock, (OUT / "received-http.jsonl").open("a") as f:
            received_count += 1
            f.write(
                json.dumps(
                    {
                        "path": self.path,
                        "body_b64": base64.b64encode(raw).decode(),
                        "safe_headers": {
                            n: v
                            for n, v in self.headers.items()
                            if n.lower()
                            in {
                                "content-type",
                                "anthropic-version",
                                "x-coworld-player-slot",
                            }
                        },
                        "received_monotonic": began,
                    }
                )
                + "\n"
            )
        if profile:
            try:
                serve_profile(self, raw, began)
            except BaseException as error:
                failures.append(repr(error))
                with (OUT / "fixture-errors.jsonl").open("a") as evidence:
                    evidence.write(
                        json.dumps({"error": repr(error), "received_monotonic": began})
                        + "\n"
                    )
                raise
            return
        body = json.loads(raw)
        slot = int(self.headers["X-Coworld-Player-Slot"])
        user = body["messages"][0]["content"]
        shift_match = re.match(r"Shift (\d+) of 8\.", user)
        assert shift_match is not None
        shift = int(shift_match[1])
        assert self.path == "/v1/messages" and 0 <= slot < 5 and 0 <= shift < 8
        assert (
            body["model"] == "anthropic/claude-haiku-4.5" and body["max_tokens"] == 800
        )
        assert ("THE BOARD:" in user) == (slot == manager)
        assert ("YOUR MACHINE:" in user) == (slot != manager)
        assert not any(
            name.lower() in {"authorization", "x-api-key", "cookie"}
            for name in self.headers
        )
        note = f"PRIVATE_FIRM_NOTE_SLOT_{slot}" if shift == 0 else ""
        action = (
            {
                "orders": ["B", "A", "B", "A"],
                "payroll": 40,
                "split": [25, 25, 25, 25],
                "directive": f"SHIFT_{shift}_MEMO" if shift % 2 else "",
                "notes": note,
            }
            if slot == manager
            else {
                "line": "A",
                "run": 6,
                "maint": 3,
                "report": f"worker {slot} reported",
                "notes": note,
            }
        )
        text = json.dumps(action, separators=(",", ":"))
        reply = (
            json.dumps(
                {
                    "model": body["model"],
                    "content": [{"type": "text", "text": text}],
                    "usage": {"input_tokens": 12, "output_tokens": 8},
                    "stop_reason": "end_turn",
                },
                indent=2,
            ).encode()
            + b"\n"
        )
        cid = str(uuid.uuid4())
        with lock:
            assert len(calls) < 80
            call = {
                "observed_HTTP_index": len(calls),
                "slot": slot,
                "shift": shift,
                "request_started_monotonic": began,
                "request": body,
                "request_body_b64": base64.b64encode(raw).decode(),
                "safe_request_headers": {
                    n: v
                    for n, v in self.headers.items()
                    if n.lower()
                    in {"content-type", "anthropic-version", "x-coworld-player-slot"}
                },
                "response_body_b64": base64.b64encode(reply).decode(),
                "response_status": 200,
                "call_id": cid,
                "request_id": "fixture-" + cid,
                "action": action,
                "fixture_only": True,
            }
            calls.append(call)
        time.sleep(0.05)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.send_header("X-Softmax-Llm-Call-Id", cid)
        self.send_header("request-id", "fixture-" + cid)
        self.end_headers()
        self.wfile.write(reply)
        self.wfile.flush()
        call["response_flushed_monotonic"] = time.monotonic()
        with lock, (OUT / "observed-http.jsonl").open("a") as f:
            f.write(json.dumps(call) + "\n")

    def do_PUT(self):
        try:
            assert (
                profile and profile["profile"] == "mixed-control-transport-publication"
            )
            retain_private(self)
        except BaseException as error:
            failures.append(repr(error))
            raise

    def log_message(self, format, *args):
        pass


fixture = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
threading.Thread(target=fixture.serve_forever, daemon=True).start()
manifest = json.loads((Path.cwd() / "coworld_manifest_template.json").read_text())
config = next(
    v["game_config"]
    for v in manifest["variants"]
    if v["id"] == (profile["variant"] if profile else "standard")
).copy()
config.update(seed=9, tokens=[f"fixture-firm-token-{n}" for n in range(5)])
(OUT / "config.json").write_text(json.dumps(config, indent=2) + "\n")
assert (
    config["shifts"] == 8
    and config["turnDelayMs"] == 400
    and config["player_connect_timeout_seconds"] == 180
)
env = {k: os.environ[k] for k in ("PATH", "HOME", "TMPDIR", "LANG") if k in os.environ}
game_env = {
    **env,
    "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{fixture.server_port}",
    "COWORLD_EPISODE_ID": str(uuid.uuid4()),
    "COWORLD_GAME_VERSION": "fixture-source",
    "COWORLD_SOURCE_REVISION": hashlib.sha256(
        json.dumps(source, sort_keys=True).encode()
    ).hexdigest(),
}
if args.capture:
    game_env["COGAME_SAVE_TRAJECTORY_URI"] = (
        f"http://127.0.0.1:{fixture.server_port}/private-trajectory"
        if profile and profile["profile"] == "mixed-control-transport-publication"
        else (OUT / "private-trajectory.jsonl").as_uri()
    )
(OUT / "environment-key-audit.json").write_text(
    json.dumps(
        {
            "game": sorted(game_env),
            "player_extra": ["COWORLD_PLAYER_WS_URL"],
            "provider_credentials_forwarded": False,
            "fixture_only": True,
        },
        indent=2,
    )
    + "\n"
)
command = [
    str(GAME),
    "--host:127.0.0.1",
    "--port:" + str(game_port),
    "--config-path:" + str(OUT / "config.json"),
    "--results-uri:" + (OUT / "results.json").as_uri(),
    "--save-replay-uri:" + (OUT / "replay.json").as_uri(),
]
(OUT / "game-command.json").write_text(json.dumps(command, indent=2) + "\n")


def observer():
    try:
        with connect(
            f"ws://127.0.0.1:{game_port}/global",
            max_size=2**20,
            max_queue=1024,
            proxy=None,
        ) as live:
            first = json.loads(live.recv(timeout=3))
            assert (
                first["type"] == "state"
                and first["game"] == "firm"
                and len(first["seats"]) == 5
                and not first["started"]
            )
            (OUT / "global-startup.json").write_text(json.dumps(first, indent=2) + "\n")
            ready.set()
            next_check = 0
            with (
                (OUT / "global-frames.jsonl").open("w") as frames,
                (OUT / "global-health-pong.jsonl").open("w") as checks,
            ):
                while not stop.is_set():
                    try:
                        raw = live.recv(timeout=0.02)
                    except TimeoutError:
                        pass
                    else:
                        data = json.loads(raw)
                        assert data["type"] == "state" and len(data["seats"]) == 5
                        frames.write(json.dumps(data) + "\n")
                        frames.flush()
                    if time.monotonic() >= next_check:
                        began = time.monotonic()
                        assert live.ping().wait(2), "Pong deadline"
                        for route in ["healthz", "client/global"]:
                            with OPENER.open(
                                f"http://127.0.0.1:{game_port}/{route}", timeout=2
                            ) as response:
                                assert response.status == 200 and response.read(512)
                        checks.write(
                            json.dumps(
                                {
                                    "elapsed_seconds": time.monotonic() - START,
                                    "Pong_health_client_seconds": time.monotonic()
                                    - began,
                                }
                            )
                            + "\n"
                        )
                        checks.flush()
                        next_check = time.monotonic() + 0.25
    except ConnectionClosed as error:
        closures.append(
            {"exception": repr(error), "elapsed_seconds": time.monotonic() - START}
        )
    except BaseException as error:  # noqa: BLE001 - preserve bounded interrupted-fixture evidence
        failures.append(repr(error))
        ready.set()


summary = {"fixture_only": True, "provider_calls": 0, "authorized_attempts": 1}
viewer = None
try:
    log = (OUT / "game.log").open("xb")
    logs.append(log)
    game = subprocess.Popen(command, env=game_env, stdout=log, stderr=subprocess.STDOUT)
    processes.append(game)
    deadline = time.monotonic() + 20
    while True:
        assert game.poll() is None, "game exited before startup"
        try:
            with OPENER.open(
                f"http://127.0.0.1:{game_port}/healthz", timeout=0.3
            ) as response:
                if response.status == 200:
                    break
        except OSError:
            pass
        assert time.monotonic() < deadline, "health startup deadline"
        time.sleep(0.05)
    viewer = threading.Thread(target=observer, daemon=True)
    viewer.start()
    assert ready.wait(5) and not failures, "global readiness before players"
    if profile:
        for entry in profile["roster"]:
            if entry["control"] == "external":
                worker = threading.Thread(
                    target=external_player, args=(entry["seat"],), daemon=True
                )
                external_threads.append(worker)
                worker.start()
                assert external_ready.wait(5) and not failures, (
                    "external registration before other seats"
                )
    for slot in range(5):
        entry = (
            next((x for x in profile["roster"] if x["seat"] == slot), None)
            if profile
            else None
        )
        if entry and entry["control"] == "external":
            continue
        extra_env = (
            {"PLAYER_SCRIPTED": "steady"}
            if entry and entry["control"] == "scripted"
            else {}
        )
        log = (OUT / f"player-{slot}.log").open("xb")
        logs.append(log)
        p = subprocess.Popen(
            [str(PLAYER)],
            env={
                **env,
                **extra_env,
                "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{game_port}/player?slot={slot}&token=fixture-firm-token-{slot}",
            },
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        processes.append(p)
    with (OUT / "resources.jsonl").open("x") as metrics:
        while game.poll() is None:
            elapsed = time.monotonic() - START
            size = sum(x.stat().st_size for x in OUT.rglob("*") if x.is_file())
            free = shutil.disk_usage(OUT).free
            resources = subprocess.run(
                [
                    "ps",
                    "-o",
                    "pid=,pcpu=,rss=",
                    "-p",
                    ",".join(
                        str(pid) for pid in [os.getpid(), *[p.pid for p in processes]]
                    ),
                ],
                capture_output=True,
                text=True,
                timeout=3,
                check=False,
            ).stdout
            metrics.write(
                json.dumps(
                    {
                        "elapsed_seconds": elapsed,
                        "artifact_bytes": size,
                        "free_bytes": free,
                        "observed_HTTP": len(calls),
                        "received_HTTP": received_count,
                        "owned_process_CPU_RSS_KiB": resources,
                    }
                )
                + "\n"
            )
            metrics.flush()
            assert (
                elapsed <= args.wall_limit_seconds
                and size <= 16 * 2**20
                and free >= 2 * 2**30
                and received_count <= http_limit
                and len(calls) <= http_limit
            ), "resource guard"
            assert not failures, "global/health/Pong failure"
            time.sleep(0.1)
    assert game.returncode == 0
    for p in processes[1:]:
        assert p.wait(timeout=3) == 0
    if profile:
        # The owned partial-response fixture can outlive Curly's native timeout.
        # Wait for its retained offer receipt without extending the QA wall limit.
        receipt_deadline = min(START + args.wall_limit_seconds, time.monotonic() + 10)
        observed_path = OUT / "observed-http.jsonl"
        while len(observed_path.read_text().splitlines()) < len(calls):
            assert not failures and time.monotonic() < receipt_deadline
            assert shutil.disk_usage(OUT).free >= 2 * 2**30
            assert (
                sum(p.stat().st_size for p in OUT.rglob("*") if p.is_file())
                <= 16 * 2**20
            )
            time.sleep(0.05)
    results = json.loads((OUT / "results.json").read_text())
    replay = json.loads((OUT / "replay.json").read_text())
    if profile:
        assert results["reason"] == "complete" and results["shifts"] == 8
        assert len(calls) == profile.get(
            "expected_HTTP_each", profile.get("expected_HTTP")
        )
        assert len([e for e in replay["events"] if e["kind"] in ["memo", "work"]]) == 40
        assert len((OUT / "received-http.jsonl").read_text().splitlines()) == len(calls)
        assert not failures
        summary.update(
            status="FULL_NATIVE_PROFILE_COMPLETE_PENDING_OFFLINE_CHECKS",
            profile=profile["profile"],
            full_native_shifts=8,
            observed_HTTP=len(calls),
            native_action_events=40,
            actual_public_normal_completion=True,
            private_capture_enabled=args.capture,
            results=results,
            normal_terminal_close_qualified_by_process0_and_public_artifacts=True,
        )
    else:
        assert len((OUT / "received-http.jsonl").read_text().splitlines()) == 40
        assert (
            results["reason"] == "complete"
            and results["shifts"] == 8
            and results["maxShifts"] == 8
            and len(calls) == 40
        )
        assert (
            results["roles"][manager] == "Manager"
            and sum(x == "Manager" for x in results["roles"]) == 1
        )
        assert sorted((x["shift"], x["slot"]) for x in calls) == [
            (s, n) for s in range(8) for n in range(5)
        ]
        actions = [e for e in replay["events"] if e["kind"] in ["memo", "work"]]
        assert len(actions) == 40 and all(not e["scripted"] for e in actions)
        assert (OUT / "private-trajectory.jsonl").exists() == args.capture, (
            "private trajectory enablement mismatch"
        )
        assert all(
            "PRIVATE_FIRM_NOTE_SLOT_" + str(slot)
            in next(
                c["request"]["messages"][0]["content"]
                for c in calls
                if c["shift"] == 1 and c["slot"] == slot
            )
            for slot in range(5)
        )
        assert all(
            "PRIVATE_FIRM_NOTE_SLOT_" + str(other)
            not in c["request"]["messages"][0]["content"]
            for c in calls
            for other in range(5)
            if other != c["slot"]
        )
        assert all(
            "SHIFT_0_MEMO" not in c["request"]["messages"][0]["content"]
            for c in calls
            if c["shift"] == 0
        )
        assert not failures
        summary.update(
            status="PASS",
            full_native_shifts=8,
            observed_HTTP=40,
            source_bound_max_submitted_HTTP=80,
            native_action_events=40,
            private_capture_enabled=args.capture,
            actual_public_normal_completion=True,
            results=results,
            global_closures=closures,
            normal_terminal_close_qualified_by_process0_and_public_artifacts=True,
        )
except BaseException as error:
    summary.update(status="FAILED_OR_PARTIAL", failure=repr(error))
    raise
finally:
    stop.set()
    for p in processes:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
    if viewer:
        viewer.join(timeout=3)
    for worker in external_threads:
        worker.join(timeout=3)
        if worker.is_alive():
            failures.append("external fixture did not settle")
    fixture.shutdown()
    fixture.server_close()
    for log in logs:
        log.close()
    summary.update(
        elapsed_seconds=time.monotonic() - START,
        viewer_failures=failures,
        global_closures=closures,
        process_exit_codes=[p.poll() for p in processes],
    )
    (OUT / "result-card.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
