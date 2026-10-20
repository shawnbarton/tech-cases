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
  *-lms*) i=0; while [ \$i -lt 50 ]; do echo "\$(date '+%Y/%m/%d %H:%M:%S.%3N'), P\$((i / 3 % 2 * 3)), \$((8001 - i / 3 % 2 * 2000)), 900, 20.5"; i=\$((i+1)); sleep 0.5; done ;;
  *driver_version*) echo 615.78.08 ;;
  *pstate,clocks.mem,clocks.gr*) echo "P5, 6001 MHz, 900 MHz" ;;
  -q) echo "    GSP Firmware Version                  : 615.78.08" ;;
esac
exit 0
EOS
printf '#!/bin/sh\n[ "$1" = -v ] && exit 0\n[ "$1" = -n ] && shift\nexec "$@"\n' > "$T/fakebin/sudo"
printf '#!/bin/sh\nprintf "method return\\n   string \\"KWin Support Information:\\nOpenGL vendor string: NVIDIA Corporation\\nOpenGL renderer string: NVIDIA GeForce RTX 4070 Laptop GPU/PCIe/SSE2\\nOpenGL version string: 4.6.0\\"\\n"\n' > "$T/fakebin/dbus-send"
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/systemd-ac-power"
cat > "$T/fakebin/bpftrace" <<'EOS'
#!/usr/bin/env python3
# Like bpftrace: installs its own SIGINT handler (even when started with SIGINT ignored).
import signal, sys, time
def stop(*_):
    print(f"{time.monotonic_ns()} END", flush=True); sys.exit(0)
signal.signal(signal.SIGINT, stop)
print("Attaching 40 probes...", file=sys.stderr, flush=True)
print(f"# t_ns EVENT fields  (main tid={sys.argv[2]})", flush=True)
while True:
    print(f"{time.monotonic_ns()} FLIPEV crtc=0 seq=0", flush=True); time.sleep(0.2)
EOS
printf '#!/bin/sh\nprintf "host  /usr/bin/Discord --type=x\\nhost  xeyes\\n"\n' > "$T/fakebin/xlsclients"
cat > "$T/fakebin/journalctl" <<'EOS'
#!/bin/sh
case "$*" in
  *--user*) python3 -c 'import time; print(f"[{time.monotonic():12.6f}] host kwin_wayland[1]: kwin_wayland_drm: atomic commit failed: Device or resource busy")' ;;
  *) python3 -c 'import time; print(f"[{time.monotonic() - 2.5:12.6f}] host kernel: nvidia-modeset: fake message")' ;;
esac
EOS
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
cp "$TBD/bin/stuttertest" "$TBD/bin/kwin-perf-summary" "$TBD/bin/stutter-analyze" "$TBD/bin/dgpu-run" "$T/tb/bin/"
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
echo "### analyze (last run, then by name)"; "$ST" analyze | show; "$ST" analyze a3-mem | grep -E '^==|nvidia-smi' | show; "$ST" analyze nope 2>&1 | show
echo "### marks during a run (shortcut-style), X11 apps, run logs"
python3 -c 'import ctypes, time; ctypes.CDLL(None).prctl(15, b"Xwayland", 0, 0, 0); time.sleep(20)' &
XPID=$!
( sleep 1; "$ST" mark shortcut; sleep 0.5; "$ST" mark half screen snow ) &
printf 'n\ny\nkonsole drag to DP-2\n' | "$ST" run s-marks --duration 4 2>&1 | grep -E '===|X11 apps|static marked|log during|Marks|t\+|log [+-]|marks had' | show
kill $XPID 2>/dev/null
cat "$T"/home/stuttertest/runs/*-s-marks/marks.txt | cut -d' ' -f2-
echo "### --trace (fake bpftrace), and refusing --trace with --smi"
printf 'n\nn\n\n' | "$ST" run t-trace --trace --duration 2 2>&1 | grep -E 'kernel trace|===' | show
tail -2 "$T"/home/stuttertest/runs/*-t-trace/trace.log | cut -d' ' -f2-
"$ST" run t-both --trace --smi --duration 1 2>&1 | tail -1 | show
echo "### logs (fake journalctl, no nvidia procfs here)"
"$ST" logs -1h 2>&1 | show
f=$(ls -t "$T"/home/stuttertest/logs-*.txt | head -1); grep -E '^== |booted|EDID file|fake' "$f" | sed "s#$T##g"
echo "### applied values recorded"; grep -h '^applied:' "$T"/home/stuttertest/runs/*/meta.txt | show
kill $KPID; sleep 0.5
echo "### outside Plasma without --smi -> refuse"; "$ST" run h-gnome --duration 1 2>&1 | show
echo "### outside Plasma with --smi"; printf 'y\n\n\n' | XDG_CURRENT_DESKTOP=GNOME "$ST" run h-gnome --smi --duration 2 2>&1 | show
echo "### report"; "$ST" report | cut -c1-300
echo "### nvidia-smi / powermizer / glxgears calls"; grep -E '^-i 0 -(lmc|rmc|lgc|rgc)|^pm --index 0 [a-z]|^glxgears' "$T/smi-calls"
echo "glxgears stand-in still running: $(pgrep -fx 'sleep 60' >/dev/null && echo yes || echo no)"
ls "$T/home/stuttertest/runs"
