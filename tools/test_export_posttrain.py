"""Export complete Firm games and join candidate decisions to resolved turn events."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
OUTPUT = Path(tempfile.mkdtemp(prefix="firm-source-export-"))
revision = subprocess.check_output(
    ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
).strip()
for variant, turns in (("standard", 8), ("silent-floor", 8)):
    output = OUTPUT / variant
    subprocess.run(
        [str(EXPORTER), str(output), "10", "1", variant],
        cwd=ROOT,
        check=True,
        timeout=600,
    )
    manifest = json.loads((output / "manifest.json").read_text())
    assert manifest["source_revision"] == revision and len(manifest["runs"]) == 10
    assert (
        not (output / "train.jsonl").exists()
        and not (output / "validation.jsonl").exists()
    )
    episodes, decisions, executions = {}, {}, {}
    for filename in ("manifest.json", "trajectories.jsonl", "execution.jsonl"):
        assert (output / filename).stat().st_mode & 0o777 == 0o600
    for line in (output / "trajectories.jsonl").read_text().splitlines():
        row = json.loads(line)
        assert row["source_revision"] == revision
        episode = row["episode_id"]
        if row["event_type"] == "episode":
            episodes[episode] = row
            continue
        decisions.setdefault(episode, []).append(row)
        assert row["visibility"] == "private"
        (attempt,) = row["attempts"]
        assert attempt["origin"] == "teacher" and attempt["request"] is None
        assert (
            attempt["platform_call_id"] is None and attempt["behavior_logprobs"] is None
        )
        assert attempt["parsed_action"] == json.loads(attempt["response"])
        if row["action_status"] == "accepted":
            assert (
                row["selected_attempt_id"] == attempt["attempt_id"]
                and attempt["accepted"]
            )
            assert row["executed_action"] == attempt["parsed_action"]
        else:
            assert row["action_status"] == "fallback" and not attempt["accepted"]
            assert row["selected_attempt_id"] is None and row["prompt"] is None
            assert row["fallback_origin"] == "engine-normalized-submission"
        view = row["observation"]
        assert all(
            "condition" not in machine and "notes" not in machine
            for machine in view["floor"]
        )
        if view["role"] == "Manager":
            assert "board" in view and "own" not in view
        else:
            assert "board" not in view and "own" in view
        metadata = view["prompt_template"]
        assert (
            metadata["bank"] == "firm-rules-v1" and metadata["variant"] == "canonical"
        )
        for message in attempt["prompt"]:
            assert (
                metadata[message["role"] + "_sha256"].lower()
                == hashlib.sha256(message["content"].encode()).hexdigest()
            )
    for line in (output / "execution.jsonl").read_text().splitlines():
        row = json.loads(line)
        executions.setdefault(row["episode_id"], []).append(row)
        assert row["visibility"] == "private" and row["source_revision"] == revision
    assert len(episodes) == 10 and set(episodes) == set(decisions) == set(executions)
    for episode, outcome in episodes.items():
        rows, applied = decisions[episode], executions[episode]
        assert (
            outcome["status"] == "completed"
            and outcome["outcome"]["reason"] == "complete"
        )
        assert (
            outcome["outcome"]["shifts"] == turns
            and len(rows) == len(applied) == turns * 5
        )
        assert sum(row["terminal"] for row in rows) == 1 and rows[-1]["terminal"]
        public, interval = None, None
        for index, (row, execution) in enumerate(zip(rows, applied, strict=True)):
            seat = int(row["seat"])
            assert row["decision_id"] == execution["decision_id"] == str(index)
            assert row["seat"] == str(seat) and execution["seat"] == seat
            view, action = row["observation"], row["executed_action"]
            snapshot = (
                view["directive"],
                view["payroll"],
                view["split"],
                [(m["setup"], m["order"], m["units"]) for m in view["floor"]],
            )
            if index % 5 == 0:
                if interval is not None:
                    assert execution["event_start"] == interval[1]
                public = snapshot
                interval = (execution["event_start"], execution["event_end"])
            assert snapshot == public and interval == (
                execution["event_start"],
                execution["event_end"],
            )
            assert interval[1] - interval[0] == len(execution["events"])
            assert execution["turn"] == view["shift"] == index // 5
            events = [
                event for event in execution["events"] if event.get("seat") == seat
            ]
            (move,) = [event for event in events if event["kind"] in ("memo", "work")]
            assert move["scripted"]
            assert action == execution["resolved_action"]
            fields = (
                ("orders", "payroll", "split")
                if view["role"] == "Manager"
                else ("line", "run", "maint")
            )
            for field in fields:
                assert action[field] == move[field]
            speech = "directive" if view["role"] == "Manager" else "report"
            assert action[speech] == move.get("say", "")
            assert action["notes"] == execution["stored_notes"] == move.get("text", "")
            if variant == "silent-floor" and view["role"] == "Worker":
                assert action["report"] == "" and row["action_status"] == "fallback"
        for seat in range(5):
            assert (
                outcome["participant_outcomes"][str(seat)]["score"]
                == outcome["outcome"]["scores"][seat]
            )
    assert {row["seed_family"] for row in episodes.values()} == {
        f"firm-{seed}" for seed in range(1, 11)
    }
    print(
        variant,
        "10 complete exports; private observations, hashes, resolved actions and outcomes PASS",
        flush=True,
    )
print("Evidence:", OUTPUT)
