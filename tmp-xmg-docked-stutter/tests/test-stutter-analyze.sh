#!/bin/bash
# stutter-analyze on synthetic runs: two monitors whose late frames come from
# one shared cause, and two whose late frames are unrelated.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
A=$HERE/../testbed/bin/stutter-analyze
T=$(mktemp -d "${TMPDIR:-/tmp}/sa.XXXXXX")
python3 - "$T" <<'PY'
import os, random, sys
root = sys.argv[1]
r = 16_666_667
H = "target pageflip timestamp,pageflip timestamp,render start,render end,safety margin,refresh duration,vrr,tearing,predicted render time\n"
def make(name, late_fn, slow_render=False):
    d = os.path.join(root, name)
    os.mkdir(d)
    open(os.path.join(d, "meta.txt"), "w").write(f"name={name}\nclock=none\nkwin_config=tb=default\ndriver=x\nstutter=yes\n")
    for o, phase in (("DP-2", 0), ("DP-3", 8_000_000)):
        with open(os.path.join(d, f"perf-{o}.csv"), "w") as f:
            f.write(H)
            for i in range(60 * 60):
                t = 10**12 + phase + i * r
                late = late_fn(o, t)
                start = t - 2 * r
                end = t + r // 10 if late and slow_render else t - r   # slow: finished after the deadline
                f.write(f"{t},{t + (r if late else 0)},{start},{end},1500000,{r},0,0,{r}\n")
            f.write("1,2,3\n")                                       # partial last row (KWin buffered write)
random.seed(1)
events = sorted(random.uniform(0, 60e9) for _ in range(25))
def shared(o, t):
    return any(0 <= t - 10**12 - e < 3 * r for e in events)
own = {o: sorted(random.uniform(0, 60e9) for _ in range(25)) for o in ("DP-2", "DP-3")}
def independent(o, t):
    return any(0 <= t - 10**12 - e < 3 * r for e in own[o])
make("shared", shared)
make("independent", independent, slow_render=True)
PY
echo "### shared cause: coincidence far above chance, frames ready but flipped late"
python3 -I "$A" "$T/shared"
echo "### independent, slow renders: coincidence near chance, frames not ready"
python3 -I "$A" "$T/independent"
echo "### usage / empty dir"
python3 -I "$A" | head -2; mkdir "$T/empty"; python3 -I "$A" "$T/empty" | sed "s#$T##"
