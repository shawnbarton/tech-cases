#!/bin/bash
# Resume re-apply failure keeps the stale marker; ENABLED=0 pause survives later trigger runs.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TBD=$HERE/../testbed
T=$(mktemp -d "${TMPDIR:-/tmp}/cf3.XXXXXX")
SYS=$T/sys; RUN=$T/run; mkdir -p "$RUN"
GPU=$SYS/bus/pci/devices/0000:01:00.0/drm/card1; mkdir -p "$GPU/card1-DP-2" "$SYS/class/power_supply/ADP1"
echo connected > "$GPU/card1-DP-2/status"; echo Mains > "$SYS/class/power_supply/ADP1/type"; echo 1 > "$SYS/class/power_supply/ADP1/online"
CALLS=$T/calls
printf '#!/bin/sh\necho "nvidia-smi $*" >> "%s"\n[ -e "%s/fail" ] && exit 1\nexit 0\n' "$CALLS" "$T" > "$T/nvidia-smi"; chmod +x "$T/nvidia-smi"
setconf() { printf 'SYSFS=%s\nRUNDIR=%s\nNVSMI=%s\nSETTLE=0\nMEM_LOCK=6001\n%s\n' "$SYS" "$RUN" "$T/nvidia-smi" "$*" > "$T/conf"; }
step() { : > "$CALLS"; out=$(NVIDIA_CLOCKFLOOR_CONF=$T/conf bash "$TBD/clockfloor/nvidia-clockfloor" 2>&1); rc=$?
  printf '%-40s rc=%s state=%-12s stale=%s out=[%s] calls=[%s]\n' "$1" "$rc" "$(cat "$RUN/nvidia-clockfloor.state" 2>/dev/null || echo -)" "$([ -e "$RUN/nvidia-clockfloor.stale" ] && echo y || echo n)" "$(echo "$out" | tr '\n' ';')" "$(tr '\n' ';' < "$CALLS")"; }
setconf "";                                   step "apply"
touch "$RUN/nvidia-clockfloor.stale" "$T/fail"; step "resume, re-apply fails"
rm -f "$T/fail";                              step "next trigger -> re-applies"
setconf "ENABLED=0";                          step "pause (ENABLED=0)"
                                              step "udev/timer run while paused"
touch "$RUN/nvidia-clockfloor.stale";         step "resume while paused"
setconf "ENABLED=1";                          step "unpause"
