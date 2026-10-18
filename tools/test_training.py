"""Play both certified firms through exports and numeric bridge decisions."""

import json
import random
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
BRIDGE = Path(sys.argv[2]).resolve()
MANIFEST = ROOT / "coworld_manifest_template.json"

subprocess.run(
    [sys.executable, str(ROOT / "tools/test_export_posttrain.py"), str(EXPORTER)],
    check=True,
)
for variant in ("standard", "silent-floor"):
    for teacher in (True, False):
        process = subprocess.Popen(
            [str(BRIDGE), str(MANIFEST), variant],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
            cwd="/tmp",
        )
        assert process.stdin is not None and process.stdout is not None
        rng = random.Random(13)

        def request(payload: dict) -> dict:
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        try:
            observation = request(
                {"kind": "reset", "players": 5, "seed": f"firm-{variant}-{teacher}"}
            )
            decisions = 0
            while observation["kind"] == "decision":
                assert observation["decision_id"] == decisions
                assert "OUTPUT FORMAT" in observation["semantic_view"]["system"]
                encoded = request({"kind": "encode"})
                assert len(encoded["values"]) == 45
                assert encoded["actions"] == [{"choice": 0}, {"choice": 1}]
                action = (
                    json.loads(request({"kind": "teacher"})["response"])
                    if teacher
                    else rng.choice(encoded["actions"])
                )
                accepted = request(
                    {
                        "kind": "step",
                        "decision_id": decisions,
                        "response": json.dumps(action),
                    }
                )
                assert accepted["kind"] == "accepted"
                observation = accepted["observation"]
                decisions += 1
            assert decisions == 40
            assert set(observation["scores"]) == {"0", "1", "2", "3", "4"}
            assert all(-1 <= value <= 1 for value in observation["utilities"].values())
            print(variant, "teacher" if teacher else "random", decisions)
        finally:
            process.stdin.close()
            process.stdout.close()
            assert process.wait(timeout=5) == 0
