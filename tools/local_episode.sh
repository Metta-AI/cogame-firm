#!/usr/bin/env bash
set -euo pipefail

mode=${1:?usage: local_episode.sh jev|steady seed [steady|taskmaster]}
seed=${2:?seed required}
opponents=${3:-steady}
port=${PORT:-18108}
case "$mode" in
  jev|steady) ;;
  *) echo "mode must be jev or steady" >&2; exit 2 ;;
esac
case "$opponents" in
  steady|taskmaster) ;;
  *) echo "opponents must be steady or taskmaster" >&2; exit 2 ;;
esac

mkdir -p tmp/bin
episode_dir=$(mktemp -d tmp/episode.XXXXXX)
episode_dir="$PWD/$episode_dir"
python3 - "$seed" "$episode_dir/config.json" <<'PY'
import json
import sys
from pathlib import Path
seed, path = sys.argv[1:]
Path(path).write_text(json.dumps({
    'tokens': [f't{i}' for i in range(5)],
    'players': [{'name': f'P{i}'} for i in range(5)],
    'seed': int(seed), 'shifts': 8, 'turnDelayMs': 0,
    'player_connect_timeout_seconds': 10,
}))
PY
nim c --hints:off -o:tmp/bin/firm src/firm.nim
nim c --hints:off -o:tmp/bin/firm-player src/firm_player.nim
tmp/bin/firm --host:127.0.0.1 --port:"$port" \
  --config-path:"$episode_dir/config.json" \
  --results-uri:"file://$episode_dir/results.json" \
  --save-replay-uri:"file://$episode_dir/episode.replay" \
  > "$episode_dir/game.log" 2>&1 &
game=$!
trap 'kill "$game" 2>/dev/null || true' EXIT
sleep 0.5
for slot in {0..4}; do
  if [ "$slot" = 0 ] && [ "$mode" = jev ]; then
    COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$port/player?slot=$slot&token=t$slot" \
      PLAYER_JEV=1 tmp/bin/firm-player \
      > "$episode_dir/player$slot.log" 2>&1 &
  else
    baseline=$opponents
    if [ "$slot" = 0 ]; then
      baseline=steady
    fi
    COWORLD_PLAYER_WS_URL="ws://127.0.0.1:$port/player?slot=$slot&token=t$slot" \
      PLAYER_SCRIPTED="$baseline" tmp/bin/firm-player \
      > "$episode_dir/player$slot.log" 2>&1 &
  fi
done
wait "$game"
python3 - "$episode_dir" <<'PY'
import json
import re
import sys
from pathlib import Path
path = Path(sys.argv[1])
results = json.loads((path / 'results.json').read_text())
replay = json.loads((path / 'episode.replay').read_text())
log = (path / 'player0.log').read_text()
usage = [tuple(map(int, match)) for match in re.findall(
    r'input_tokens (\d+) output_tokens (\d+)', log)]
print(json.dumps({
    'artifacts': str(path), 'seat0_role': results['roles'][0],
    'seat0_score': results['scores'][0], 'profit': results['profit'],
    'jev_calls': len(usage), 'input_tokens': sum(item[0] for item in usage),
    'output_tokens': sum(item[1] for item in usage),
    'seat0_scripted': sum(event['scripted'] for event in replay['events']
        if event['kind'] in ('memo', 'work') and event['seat'] == 0),
}))
PY
