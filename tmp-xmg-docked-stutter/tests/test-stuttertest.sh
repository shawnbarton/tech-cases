#!/bin/bash
# End-to-end test of stuttertest with a fake kwin_wayland (a process named
# kwin_wayland that keeps its frame logs open, like the real one), plus fake
# nvidia-smi, sudo, dbus-send and glxgears.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TBD=$HERE/../testbed
T=$(mktemp -d "${TMPDIR:-/tmp}/st.XXXXXX")
mkdir -p "$T/fakebin" "$T/kwincwd" "$T/home"

cat > "$T/fakekwin.py" <<'PY'
#!/usr/bin/env python3
import ctypes, os, sys, time
ctypes.CDLL(None).prctl(15, b"kwin_wayland", 0, 0, 0)    # PR_SET_NAME: comm = kwin_wayland
os.chdir(sys.argv[1])
open("kwin perf statistics OLD-1.csv", "w").write("stale file from an earlier session\n")
os.utime("kwin perf statistics OLD-1.csv", (time.time() - 86400, time.time() - 86400))
r = 16_666_667
files = {o: open(f"kwin perf statistics {o}.csv", "w") for o in ("DP-2", "DP-3")}
for f in files.values():
    f.write("target pageflip timestamp,pageflip timestamp,render start,render end,safety margin,refresh duration,vrr,tearing,predicted render time\n")
i = 0
while True:
    t = time.monotonic_ns()
    for o, f in files.items():
        late = (o == "DP-2" and i % 20 == 0)
        ahead = (o == "DP-3" and i % 4 == 0)           # 25% of DP-3 frames started > 1 refresh early
        start = t - (r + r // 2 if ahead else r // 2)
        f.write(f"{t},{t + (r if late else 0)},{start},{start + r // 3},1000000,{r},0,0,{r // 3}\n")
        f.flush()
    i += 1
    time.sleep(r / 1e9)
PY
chmod +x "$T/fakekwin.py"
printf '#!/bin/sh\necho "kwin 6.7.5"\n' > "$T/fakebin/kwin_wayland"
cat > "$T/fakebin/nvidia-smi" <<EOS
#!/bin/sh
echo "\$*" >> "$T/smi-calls"
case "\$*" in
  *query-supported-clocks=memory*) printf '8001\n8001\n7001\n6001\n810\n405\n' ;;
  *clocks.max.graphics*) echo 2475 ;;
  *-lms*) i=0; while [ \$i -lt 50 ]; do echo "2026/10/19 12:00:00.000, P\$((i % 2 * 3)), \$((8001 - i % 2 * 2000)), 900, 20.5"; i=\$((i+1)); sleep 0.5; done ;;
  *driver_version*) echo 615.78.08 ;;
  *pstate,clocks.mem,clocks.gr*) echo "P5, 6001 MHz, 900 MHz" ;;
  -q) echo "    GSP Firmware Version                  : 615.78.08" ;;
esac
exit 0
EOS
printf '#!/bin/sh\n[ "$1" = -v ] && exit 0\n[ "$1" = -n ] && shift\nexec "$@"\n' > "$T/fakebin/sudo"
printf '#!/bin/sh\nprintf "method return\\n   string \\"KWin Support Information:\\nOpenGL vendor string: NVIDIA Corporation\\nOpenGL renderer string: NVIDIA GeForce RTX 4070 Laptop GPU/PCIe/SSE2\\nOpenGL version string: 4.6.0\\"\\n"\n' > "$T/fakebin/dbus-send"
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/systemd-ac-power"
cat > "$T/fakebin/systemctl" <<EOS
#!/bin/sh
case "\$*" in
  "--user show-environment") printf 'HOME=/x\nKWIN_LOG_PERFORMANCE_DATA=1\nKWIN_DRM_DISABLE_TRIPLE_BUFFERING=1\n' ;;
  *WorkingDirectory*plasma-kwin_wayland*) echo "$T/kwincwd" ;;
esac
exit 0
EOS
printf '#!/bin/sh\necho "glxgears env: offload=$__NV_PRIME_RENDER_OFFLOAD vendor=$__GLX_VENDOR_LIBRARY_NAME prime=$DRI_PRIME" >> "%s/smi-calls"\nexec sleep 60\n' "$T" > "$T/fakebin/glxgears"
chmod +x "$T/fakebin/"*
mkdir -p "$T/tb/bin" "$T/tb/kwin"
cp "$TBD/bin/stuttertest" "$TBD/bin/kwin-perf-summary" "$TBD/bin/dgpu-run" "$T/tb/bin/"
cp "$TBD/kwin/50-kwin-docked-gpu.sh" "$T/tb/kwin/"
cat > "$T/tb/bin/nv-powermizer" <<EOS
#!/bin/sh
echo "pm \$*" >> "$T/smi-calls"
state="$T/pm-mode"; [ -e "\$state" ] || echo auto > "\$state"
if [ \$# -gt 2 ]; then [ -e "$T/pm-ignored" ] || echo "\$3" > "\$state"; exit 0; fi
echo "current: \$(cat "\$state")"; echo "supported: adaptive max auto consistent"
EOS
chmod +x "$T/tb/bin/nv-powermizer"
export PATH="$T/fakebin:$PATH" HOME="$T/home"
KWIN_LOG_PERFORMANCE_DATA=1 KWIN_DRM_DISABLE_TRIPLE_BUFFERING=1 python3 "$T/fakekwin.py" "$T/kwincwd" &
KPID=$!
trap 'kill $KPID 2>/dev/null' EXIT
sleep 1.5
ST="$T/tb/bin/stuttertest"
show() { grep -v "s left" | sed "s#$T##g"; }

echo "### kwin set/show"; "$ST" kwin set tb=off perf=on margin=3000 | show
echo "### frame logs found (must be DP-2 and DP-3 only, not the stale file)"; "$ST" info 2>/dev/null | grep 'frame logs open' | show
echo "### run baseline (3 s)"; printf 'y\nn\nonly while dragging\n' | "$ST" run a1 --duration 3 2>&1 | show
echo "### run mem lock + smi (3 s)"; printf 'n\nn\n\n' | "$ST" run a3-mem --clock mem --smi --duration 3 2>&1 | show
echo "### PowerMizer restores the previous mode (auto)"; printf '\n' | "$ST" run a3-pm --clock pm-consistent --duration 2 2>&1 | grep -E 'PowerMizer|===' | show; echo "mode after run: $(cat "$T/pm-mode")"
echo "### PowerMizer ignored by the GPU -> refuse"; touch "$T/pm-ignored"; printf '\n' | "$ST" run a3-pm2 --clock pm-max --duration 2 2>&1 | tail -1 | show; rm -f "$T/pm-ignored"
echo "### p0 + gr combo (2 s)"; printf 'maybe\nY\n\nleft monitor static\n' | "$ST" run a3-combo --clock gr=1200,p0 --duration 2 2>&1 | grep -E 'load on|floor|===|perf-' | show
echo "### p0ctl without an Intel GPU (this container) -> clear error"; printf '\n' | "$ST" run a3-p0ctl --clock p0ctl --duration 1 2>&1 | tail -1 | show
echo "### bad input"; "$ST" run 'bad name' 2>&1 | show; "$ST" run x --clock turbo 2>&1 | show; "$ST" run y --clock mem=fast 2>&1 | show
echo "### KWin /proc entries root-only (Fedora: CAP_SYS_NICE) -> systemd env + working dir"
STUTTERTEST_NO_PROC=1 "$ST" info 2>/dev/null | grep -E 'KWIN_\* in running|KWIN_LOG|frame logs open' | show
printf 'n\nn\n\n' | STUTTERTEST_NO_PROC=1 "$ST" run a1-noproc --duration 2 2>&1 | grep -E '===|perf-|error|stuttertest:' | show
echo "### applied values recorded"; grep -h '^applied:' "$T"/home/stuttertest/runs/*/meta.txt | show
kill $KPID; sleep 0.5
echo "### outside Plasma without --smi -> refuse"; "$ST" run h-gnome --duration 1 2>&1 | show
echo "### outside Plasma with --smi"; printf 'y\n\n\n' | XDG_CURRENT_DESKTOP=GNOME "$ST" run h-gnome --smi --duration 2 2>&1 | show
echo "### report"; "$ST" report | cut -c1-300
echo "### nvidia-smi / powermizer / glxgears calls"; grep -E '^-i 0 -(lmc|rmc|lgc|rgc)|^pm --index 0 [a-z]|^glxgears' "$T/smi-calls"
echo "glxgears stand-in still running: $(pgrep -fx 'sleep 60' >/dev/null && echo yes || echo no)"
ls "$T/home/stuttertest/runs"
