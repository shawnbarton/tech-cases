#!/bin/bash
# Exercise the revised nvidia-clockfloor against a fake sysfs, nvidia-smi and nv-powermizer.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TBD=$HERE/../testbed
T=$(mktemp -d "${TMPDIR:-/tmp}/cf2.XXXXXX")
SYS=$T/sys; RUN=$T/run; mkdir -p "$RUN"
GPU=$SYS/bus/pci/devices/0000:01:00.0/drm/card1
mkdir -p "$GPU/card1-DP-2" "$GPU/card1-eDP-2" "$SYS/class/power_supply/BAT0" "$SYS/class/power_supply/ADP1" "$SYS/class/power_supply/ucsi-source-psy-USBC000:001"
echo Battery > "$SYS/class/power_supply/BAT0/type"
echo Mains > "$SYS/class/power_supply/ADP1/type"
echo USB > "$SYS/class/power_supply/ucsi-source-psy-USBC000:001/type"; echo 0 > "$SYS/class/power_supply/ucsi-source-psy-USBC000:001/online"
echo Device > "$SYS/class/power_supply/ucsi-source-psy-USBC000:001/scope"
echo connected > "$GPU/card1-eDP-2/status"
CALLS=$T/calls
cat > "$T/nvidia-smi" <<EOS
#!/bin/sh
echo "nvidia-smi \$*" >> "$CALLS"
case "\$*" in *clocks.max.graphics*) cat "$T/max" 2>/dev/null || echo 2475 ;; esac
case "\$*" in *-r[mg]c*) [ -e "$T/failreset" ] && exit 1 ;; esac
[ -e "$T/fail" ] && exit 1
exit 0
EOS
printf '#!/bin/sh\necho "nv-powermizer $*" >> "%s"\nexit 0\n' "$CALLS" > "$T/nv-powermizer"
chmod +x "$T/nvidia-smi" "$T/nv-powermizer"
CONF=$T/conf
setconf() { printf 'SYSFS=%s\nRUNDIR=%s\nNVSMI=%s\nNV_POWERMIZER=%s\nSETTLE=0\n%s\n' "$SYS" "$RUN" "$T/nvidia-smi" "$T/nv-powermizer" "$*" > "$CONF"; }
step() {
    : > "$CALLS"
    out=$(NVIDIA_CLOCKFLOOR_CONF=$CONF bash "$TBD/clockfloor/nvidia-clockfloor" 2>&1); rc=$?
    printf '%-44s rc=%s state=%-22s out=[%s] calls=[%s]\n' "$1" "$rc" "$(cat "$RUN/nvidia-clockfloor.state" 2>/dev/null || echo -)" "$(echo "$out" | tr '\n' ';')" "$(tr '\n' ';' < "$CALLS")"
}
ac() { echo "$1" > "$SYS/class/power_supply/ADP1/online"; }
dp() { echo "$1" > "$GPU/card1-DP-2/status"; }

setconf "MEM_LOCK=6001"
ac 1; dp disconnected; step "AC, undocked (only MUX eDP connected)"
dp connected;          step "AC + docked -> apply"
                       step "again -> no-op"
setconf "MEM_LOCK=8001"; step "MEM_LOCK changed -> re-apply"
setconf "MEM_LOCK=
GR_MIN=900";           step "graphics floor only"
echo "[N/A]" > "$T/max"; touch "$RUN/nvidia-clockfloor.stale"; step "stale, max N/A, GR only -> skipped"
rm -f "$T/max"; setconf "MEM_LOCK=8001
GR_MIN=900"; echo 800 > "$T/max"; step "GR_MIN >= max -> skipped, mem ok"
rm -f "$T/max"
setconf "MEM_LOCK=80x1"; step "invalid config -> release + rc1"
setconf "MEM_LOCK=
GR_MIN=";              step "locks with nothing set -> invalid"
setconf "MEM_LOCK=6001"; step "valid again -> apply"
touch "$T/failreset"; ac 0; step "battery, reset fails -> keep state"
rm -f "$T/failreset";  step "retry -> released"
echo 1 > "$SYS/class/power_supply/ucsi-source-psy-USBC000:001/online"; step "USB PD supply online (scope=Device) -> AC"
echo 0 > "$SYS/class/power_supply/ucsi-source-psy-USBC000:001/online"; ac 1
setconf "METHOD=powermizer"; step "switch to powermizer"
setconf "METHOD=powermizer
PM_MODE=max";          step "PM_MODE changed -> re-apply"
setconf "ENABLED=0";   step "disabled -> release"
