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
d = os.path.join(root, "shared")
with open(os.path.join(d, "meta.txt"), "a") as f:
    f.write(f"t0_mono_ns={10**12}\nx11_apps=discord\n")
e = 10**12 + int(events[3])
with open(os.path.join(d, "marks.txt"), "w") as f:
    f.write(f"{e + 100_000_000} static\n{10**12 + 59 * 10**9} shortcut\n")
with open(os.path.join(d, "kernel.log"), "w") as f:
    f.write(f"[{(e + 300_000_000) / 1e9:12.6f}] host kernel: example line near the first mark\n")
    f.write(f"[{(e + 9 * 10**9) / 1e9:12.6f}] host kernel: far from any mark\n")
PY
echo "### shared cause: coincidence far above chance, frames ready but flipped late"
python3 -I "$A" "$T/shared"
echo "### independent, slow renders: coincidence near chance, frames not ready"
python3 -I "$A" "$T/independent"
echo "### usage / empty dir"
python3 -I "$A" | head -2; mkdir "$T/empty"; python3 -I "$A" "$T/empty" | sed "s#$T##"
echo "### late-frame kinds on hand-made frames (asserted)"
mkdir "$T/kinds"
python3 - "$T/kinds" <<'PY'
import sys
r = 16_666_667
H = "target pageflip timestamp,pageflip timestamp,render start,render end,safety margin,refresh duration,vrr,tearing,predicted render time\n"
rows, t, flip = [], 10**12, None
def add(target, late, span_ms):
    global flip
    flip = target + (r if late else 0)
    rows.append(f"{target},{flip},{target - 2 * r},{target - 2 * r + int(span_ms * 1e6)},2000000,{r},0,0,{r}\n")
add(t, False, 3)                 # first frame
add(flip + r, False, 3)          # back-to-back, on time
add(flip + 3 * r, True, 2)       # first after a pause, late, new content (span = 2 ms)
add(flip, True, 1)               # knock-on (planned before the late flip landed), nothing new
add(flip + r, False, 3)          # back-to-back, on time
add(flip + r, True, 3)           # back-to-back, late, new content
open(f"{sys.argv[1]}/perf-DP-2.csv", "w").write(H + "".join(rows))
open(f"{sys.argv[1]}/meta.txt", "w").write("name=kinds\n")
PY
out=$(python3 -I "$A" "$T/kinds")
echo "$out" | grep -E 'kinds:|late rate'
ok=1
echo "$out" | grep -q 'kinds: 1 knock-on, 1 first after a pause, 1 back-to-back; 2 of 3 delayed new content' || ok=
echo "$out" | grep -q 'late rate after a pause: 1/1 (100.0%); back-to-back: 1/3 (33.3%)' || ok=
if [ -n "$ok" ]; then echo "kinds: as expected"; else echo "FAIL: late-frame kinds changed"; exit 1; fi
