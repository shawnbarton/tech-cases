#!/bin/bash
# End-to-end test of stuttertest with a fake kwin_wayland, nvidia-smi, sudo and dbus-send.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TBD=$HERE/../testbed
TB=$TBD
T=$(mktemp -d "${TMPDIR:-/tmp}/st.XXXXXX")
mkdir -p "$T/fakebin" "$T/kwincwd" "$T/home"
cat > "$T/fakebin/kwin_wayland" <<'PY'
#!/usr/bin/env python3
import os, sys, time
if "--version" in sys.argv:
    print("kwin 6.8.1"); sys.exit(0)
os.chdir(sys.argv[1])
r = 16_666_667
files = {o: open(f"kwin perf statistics {o}.csv", "w") for o in ("DP-2", "DP-3")}
for f in files.values():
    f.write("target pageflip timestamp,pageflip timestamp,render start,render end,safety margin,refresh duration,vrr,tearing,predicted render time\n")
i = 0
while True:
    t = time.monotonic_ns()
    for o, f in files.items():
        late = (o == "DP-2" and i % 20 == 0)
        f.write(f"{t},{t + (r if late else 0)},{t - r},{t - r + r // 3},1000000,{r},0,0,{r // 3}\n")
        f.flush()
    i += 1
    time.sleep(r / 1e9)
PY
mv "$T/fakebin/kwin_wayland" "$T/fakekwin.py"; chmod +x "$T/fakekwin.py"
cat > "$T/stub.c" <<C
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--version") == 0) { puts("kwin 6.8.1"); return 0; }
    if (argc > 1 && chdir(argv[1]) != 0) return 1;
    pid_t p = fork();
    if (p == 0) { execl("$T/fakekwin.py", "fakekwin.py", ".", (char *)0); _exit(127); }
    int st; waitpid(p, &st, 0); return 0;
}
C
gcc -o "$T/fakebin/kwin_wayland" "$T/stub.c"
cat > "$T/fakebin/nvidia-smi" <<EOS
#!/bin/sh
echo "\$*" >> "$T/smi-calls"
case "\$*" in
  *query-supported-clocks=memory*) printf '8001\n8001\n7001\n6001\n810\n405\n' ;;
  *clocks.max.graphics*) echo 2475 ;;
  *driver_version*) echo 595.104.02 ;;
  *-lms*) i=0; while [ \$i -lt 50 ]; do echo "2026/10/19 12:00:00.000, P\$((i % 2 * 3)), \$((8001 - i % 2 * 2000)), 900, 20.5"; i=\$((i+1)); sleep 0.5; done ;;
  *pstate,clocks.mem,clocks.gr*) echo "P5, 6001 MHz, 900 MHz" ;;
esac
exit 0
EOS
printf '#!/bin/sh\n[ "$1" = -v ] && exit 0\nexec "$@"\n' > "$T/fakebin/sudo"
printf '#!/bin/sh\nprintf "method return\\n   string \\"KWin Support Information:\\nOpenGL vendor string: NVIDIA Corporation\\nOpenGL renderer string: NVIDIA GeForce RTX 4070 Laptop GPU/PCIe/SSE2\\nOpenGL version string: 4.6.0\\"\\n"\n' > "$T/fakebin/dbus-send"
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/systemd-ac-power"
printf '#!/bin/sh\necho "glxgears env: $__NV_PRIME_RENDER_OFFLOAD $__GLX_VENDOR_LIBRARY_NAME $__GL_SYNC_TO_VBLANK" >> "%s/smi-calls"\nexec sleep 60\n' "$T" > "$T/fakebin/glxgears"
chmod +x "$T/fakebin/"*
# fake nv-powermizer next to a copy of stuttertest
mkdir -p "$T/tb/bin" "$T/tb/kwin"
cp "$TB/bin/stuttertest" "$TB/bin/kwin-perf-summary" "$TB/bin/dgpu-run" "$T/tb/bin/"
cp "$TB/kwin/50-kwin-docked-gpu.sh" "$T/tb/kwin/"
printf '#!/bin/sh\necho "pm $*" >> "%s/smi-calls"\n[ $# -gt 2 ] || echo "current: adaptive"\n' "$T" > "$T/tb/bin/nv-powermizer"; chmod +x "$T/tb/bin/nv-powermizer"
export PATH="$T/fakebin:$PATH" HOME="$T/home"
KWIN_LOG_PERFORMANCE_DATA=1 KWIN_DRM_DISABLE_TRIPLE_BUFFERING=1 "$T/fakebin/kwin_wayland" "$T/kwincwd" &
KPID=$!
sleep 1.5
trap 'pkill -f "$T/fakekwin.py"; kill $KPID 2>/dev/null' EXIT
ST="$T/tb/bin/stuttertest"
echo "### kwin install/set/show"; "$ST" kwin set tb=off perf=on gpu=nvidia | sed "s#$T##g"
echo "### run baseline (3 s)"; printf '4\n' | "$ST" run baseline --duration 3 2>&1 | sed "s#$T##g"
echo "### run mem lock + smi (3 s)"; printf '5\n' | "$ST" run memlock --clock mem --smi --duration 3 2>&1 | sed "s#$T##g"
echo "### run pm-consistent (2 s)"; printf '\n' | "$ST" run pmtest --clock pm-consistent --duration 2 2>&1 | sed "s#$T##g"
echo "### bad name / bad clock / bad value"; "$ST" run 'bad name' 2>&1 | sed "s#$T##g"; "$ST" run x --clock turbo 2>&1 | sed "s#$T##g"; "$ST" run y --clock mem=fast 2>&1 | sed "s#$T##g"
echo "### p0 + gr combo (2 s)"; printf '3\n' | "$ST" run combo --clock gr=1200,p0 --duration 2 2>&1 | sed "s#$T##g"
echo "### report"; "$ST" report
echo "### nvidia-smi / powermizer calls"; grep -E '^-i 0 -(lmc|rmc|lgc|rgc)|^pm|^glxgears' "$T/smi-calls"; echo "glxgears still running: $(pgrep -c -f 'sleep 60' || true)"
kill $KPID
ls "$T/home/stuttertest/runs"
