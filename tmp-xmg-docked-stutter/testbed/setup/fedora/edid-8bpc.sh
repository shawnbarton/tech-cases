#!/bin/bash
# Make a monitor's EDID say 8 bits per colour, to test whether the dock-port static
# needs the 10-bit (30bpp) output the NVIDIA driver picks for these monitors (Windows uses 8).
#
#   ./edid-8bpc.sh status              override settings, and the depth NVIDIA really sends
#   ./edid-8bpc.sh try DP-2 [DP-3]     8 bpc until reboot: sets the override, re-sets the
#                                      monitor's mode (it blinks twice), checks the depth
#   ./edid-8bpc.sh undo                back to the monitors' own EDIDs, same steps
#   ./edid-8bpc.sh boot DP-2 [DP-3]    8 bpc from every boot on; then reboot
#   ./edid-8bpc.sh boot-off            remove the boot setting; then reboot
#
# How it works with NVIDIA: the kernel's EDID override (drm.edid_firmware) reaches NVKMS
# through nvidia-drm (overrideEdid), and NVKMS drives a DP monitor at the EDID's bits per
# colour unless bandwidth forbids it (580/615: nvkms-dpy.c, nvkms-evo.c). The new depth only
# applies at the next full modeset, and only /proc/driver/nvidia-modeset/heads shows it
# (nv-heads): the sysfs EDID and KWin show DRM's copy. Only byte 20 and the checksum change;
# edid-decode checks the result. Run 'try' and 'undo' inside the Plasma session.
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"

NV_PCI=0000:01:00.0
NV_HEADS=$HERE/../../bin/nv-heads
# SETUP_SYS / SETUP_DEBUGFS / SETUP_FIRMWARE / SETUP_CMDLINE / SETUP_KCONFIG exist for the test suite only.
SYS=${SETUP_SYS:-/sys}
DEBUGFS=${SETUP_DEBUGFS:-/sys/kernel/debug}
FWDIR=${SETUP_FIRMWARE:-/usr/lib/firmware}/edid
CMDLINE=${SETUP_CMDLINE:-/proc/cmdline}
KCONFIG=${SETUP_KCONFIG:-/lib/modules/$(uname -r)/config}
PARAM=$SYS/module/drm/parameters/edid_firmware
DRACUT_CONF=$ETC/dracut.conf.d/90-xmg-edid-8bpc.conf
WORK=${XDG_STATE_HOME:-$HOME/.local/state}/xmg-edid
PREFIX=xmg-8bpc
# Written to clear the runtime setting: names no connector and leaves no fallback entry,
# so the kernel uses each monitor's own EDID and logs nothing (drm_edid_load.c).
CLEARED=,

# EDID helper: "info FILE" prints "bpc name serial"; "patch IN OUT" writes the 8 bpc copy.
edid_py() {
    python3 -I - "$@" <<'EOF'
import sys
mode, src = sys.argv[1], sys.argv[2]
e = bytearray(open(src, "rb").read())
if len(e) < 128 or e[:8] != bytes.fromhex("00ffffffffffff00"):
    sys.exit(f"{src}: not an EDID")
if sum(e[:128]) % 256:
    sys.exit(f"{src}: bad checksum in the base block")
bpc = {1: 6, 2: 8, 3: 10, 4: 12, 5: 14, 6: 16}.get((e[20] >> 4) & 7, 0) if e[20] & 0x80 else 0
name = serial = "?"
for off in range(54, 126, 18):
    d = e[off:off + 18]
    if d[:3] == b"\0\0\0" and d[3] in (0xFC, 0xFF):
        text = d[5:18].split(b"\n")[0].decode("ascii", "replace").strip()
        if d[3] == 0xFC:
            name = text
        else:
            serial = text
if mode == "info":
    print(bpc, name.replace(" ", "_"), serial.replace(" ", "_"))
    sys.exit(0)
if (e[18], e[19]) != (1, 4) or not e[20] & 0x80:
    sys.exit(f"{src}: needs a digital EDID 1.4 (bits per colour live in byte 20 only there)")
e[20] = (e[20] & 0x8F) | (2 << 4)          # keep 'digital' and the interface code (DisplayPort)
e[127] = (-sum(e[:127])) % 256
open(sys.argv[3], "wb").write(e)
EOF
}

# Connected connectors on the NVIDIA GPU, as sysfs directories.
nv_connectors() {
    local c
    for c in "$SYS"/bus/pci/devices/"$NV_PCI"/drm/card*/card*-*; do
        [ -r "$c/status" ] && [ "$(cat "$c/status")" = connected ] && echo "$c"
    done
}
conn_dir() {
    local c
    for c in "$SYS"/bus/pci/devices/"$NV_PCI"/drm/card*/card*-"$1"; do [ -e "$c" ] && { echo "$c"; return; }; done
    return 1
}
check_tools() { command -v edid-decode >/dev/null || warn "edid-decode is missing (01-base.sh installs it); skipping the conformity check"; }
in_session() {
    command -v kscreen-doctor >/dev/null && [ -n "${WAYLAND_DISPLAY:-}" ] ||
        die "run this inside the Plasma session: it re-sets the monitor's mode with kscreen-doctor"
}
runtime_value() { cat "$PARAM" 2>/dev/null || true; }

# Build the 8 bpc copy of CONNECTOR's EDID in $WORK, keep the original once, check it.
build() {
    local conn=$1 dir info bpc name serial out orig fails0 fails1
    dir=$(conn_dir "$conn") || die "$conn is not a connector on the NVIDIA GPU (see ./edid-8bpc.sh status)"
    [ "$(cat "$dir/status")" = connected ] || die "$conn: no monitor connected"
    mkdir -p "$WORK"
    cat "$dir/edid" > "$WORK/$conn.current.bin"
    [ -s "$WORK/$conn.current.bin" ] || die "$conn: the kernel shows no EDID (reboot after a driver change, monitor on?)"
    info=$(edid_py info "$WORK/$conn.current.bin") || exit 1
    read -r bpc name serial <<< "$info"
    orig=$WORK/$conn-$serial.orig.bin
    [ "$bpc" = 8 ] && [ -e "$orig" ] || cp "$WORK/$conn.current.bin" "$orig"
    out=$WORK/$PREFIX-$conn-$serial.bin
    edid_py patch "$orig" "$out" || exit 1
    if command -v edid-decode >/dev/null; then
        fails0=$(edid-decode --check "$orig" 2>&1 | grep -ci 'fail' || true)
        fails1=$(edid-decode --check "$out" 2>&1 | grep -ci 'fail' || true)
        [ "$fails1" -le "$fails0" ] || die "$conn: the patched EDID fails more conformity checks ($fails1) than the original ($fails0); not using it"
        edid-decode "$out" > "$WORK/$conn.decoded.txt" 2>&1 || true
        grep -q 'Bits per primary color channel: 8' "$WORK/$conn.decoded.txt" || die "$conn: edid-decode doesn't read 8 bpc from the patched EDID"
    fi
    echo "$conn: $name ($serial), EDID says $bpc bpc now; 8 bpc copy: $out" >&2
    echo "$out"
}

# Mode facts for CONNECTOR from kscreen-doctor: "cur temp" mode ids (temp = the lowest-refresh
# mode of the same size, which needs the least bandwidth), DISABLED, or nothing if not found.
modes_of() {
    kscreen-doctor -j 2>/dev/null | python3 -I -c '
import json, sys
conn = sys.argv[1]
for o in json.load(sys.stdin).get("outputs", []):
    if o.get("name") != conn:
        continue
    if not o.get("enabled"):
        print("DISABLED"); break
    modes = {str(m["id"]): m for m in o.get("modes", [])}
    cur = modes.get(str(o.get("currentModeId")))
    if not cur:
        break
    same = [m for k, m in modes.items() if k != str(cur["id"]) and m.get("size") == cur.get("size")]
    if same:
        temp = min(same, key=lambda m: m.get("refreshRate", 0))
        print(cur["id"], temp["id"])
    else:
        print(cur["id"], "-")
    break
' "$1" || true
}
current_mode() { kscreen-doctor -j 2>/dev/null | python3 -I -c '
import json, sys
for o in json.load(sys.stdin).get("outputs", []):
    if o.get("name") == sys.argv[1]:
        print(o.get("currentModeId"))
' "$1" || true; }
kd() {   # kscreen-doctor, non-fatal; its messages go to stdout and its exit status is unreliable
    local out
    if [ -n "$DRYRUN" ]; then echo "[dry-run] kscreen-doctor $*"; return 0; fi
    out=$(kscreen-doctor "$@" 2>&1) || true
    case $out in *"not found"*|*failed*) warn "kscreen-doctor $*: $out"; return 1 ;; esac
    return 0
}

# A full modeset makes NVKMS pick the depth again: switch to another mode of the same size
# and back (keeps rotation, scale and position). If interrupted, it switches back first.
# Returns 1 if no modeset could be confirmed.
force_modeset() {
    local conn=$1 info cur temp
    info=$(modes_of "$conn")
    case $info in
        '') warn "$conn: not among KWin's outputs (monitor off?); skipped"; return 1 ;;
        DISABLED) warn "$conn: disabled in Display settings; skipped (the override applies when it's enabled)"; return 1 ;;
    esac
    read -r cur temp <<< "$info"
    if [ "$temp" = - ]; then
        warn "$conn: no other mode of the same size to switch to; skipped"
        return 1
    fi
    trap 'kscreen-doctor "output.'"$conn"'.mode.'"$cur"'" >/dev/null 2>&1; exit 130' INT TERM
    kd "output.$conn.mode.$temp" || { trap - INT TERM; return 1; }
    [ -n "$DRYRUN" ] || sleep 3
    if [ -z "$DRYRUN" ] && [ "$(current_mode "$conn")" != "$temp" ]; then
        trap - INT TERM
        warn "$conn: KWin didn't switch modes, so no modeset happened"
        return 1
    fi
    kd "output.$conn.mode.$cur" || warn "$conn: switching back failed; set the mode in Display settings (it was mode $cur)"
    trap - INT TERM
    [ -n "$DRYRUN" ] || sleep 3
    return 0
}

# Make the kernel re-read CONNECTOR's EDID, re-set its mode, and report the depth.
apply() {
    local conn=$1 dir depth
    dir=$(conn_dir "$conn") || return 0
    [ "$(cat "$dir/status" 2>/dev/null)" = connected ] || { warn "$conn: no monitor connected; skipped"; return 0; }
    srun sh -c "echo detect > '$dir/status'"
    if ! force_modeset "$conn"; then
        echo "$conn: no modeset, so its depth didn't change (not a result)"
        return 0
    fi
    depth=$("$NV_HEADS" --depth "$conn" 2>/dev/null) || depth='unknown'
    echo "$conn now gets: $depth"
}

backup_kwin_config() {
    local f=$HOME/.config/kwinoutputconfig.json
    [ -e "$f" ] || return 0
    mkdir -p "$WORK"
    cp "$f" "$WORK/kwinoutputconfig.json.$(date +%Y%m%d-%H%M%S)"
}

# The NVIDIA GPU's DRM debugfs directory (root-only; unavailable under Secure Boot lockdown).
dri_debugfs() {
    local d
    for d in $(sudo -n sh -c "ls -d '$DEBUGFS'/dri/*/" 2>/dev/null); do
        sudo -n grep -qs "$NV_PCI" "${d}name" && { echo "${d%/}"; return 0; }
    done
    return 1
}
# Connectors with a debugfs EDID override (an earlier version of this script used those;
# the kernel prefers it over drm.edid_firmware).
debugfs_overrides() {
    local dbg c conn
    dbg=$(dri_debugfs) || return 0
    for c in $(nv_connectors); do
        conn=${c##*/card[0-9]-}
        [ "$(sudo -n cat "$dbg/$conn/edid_override" 2>/dev/null | wc -c)" -gt 0 ] && echo "$conn"
    done
    return 0
}

# Connectors the 8 bpc EDID may still be active on: named in the runtime value, showing an
# 8 bpc EDID in sysfs that the saved original doesn't have, or getting 24bpp from NVIDIA.
overridden() {
    local rt entry c conn info bpc
    rt=$(runtime_value)
    for entry in ${rt//,/ }; do case $entry in *:*) echo "${entry%%:*}" ;; esac; done
    debugfs_overrides
    for c in $(nv_connectors); do
        conn=${c##*/card[0-9]-}
        info=$(edid_py info "$c/edid" 2>/dev/null) || continue
        read -r bpc _ _ <<< "$info"
        [ "$bpc" = 8 ] && ls "$WORK/$conn"-*.orig.bin >/dev/null 2>&1 && echo "$conn"
        case $("$NV_HEADS" --depth "$conn" 2>/dev/null) in 24bpp*) echo "$conn" ;; esac
    done
}

cmd_status() {
    local c conn info bpc name serial boot rt dbgov
    [ -r "$KCONFIG" ] && { grep -q '^CONFIG_DRM_LOAD_EDID_FIRMWARE=y' "$KCONFIG" && echo "kernel: can load EDID files" || echo "kernel: CONFIG_DRM_LOAD_EDID_FIRMWARE is off; this script can't work"; }
    boot=$(tr ' ' '\n' < "$CMDLINE" | grep '^drm.edid_firmware=' || true)
    rt=$(runtime_value)
    echo "boot setting:    ${boot:-none}"
    echo "current setting: $( [ -z "$rt" ] || [ "$rt" = "$CLEARED" ] && echo none || echo "$rt")"
    dbgov=$(debugfs_overrides | paste -sd' ')
    [ -z "$dbgov" ] || echo "debugfs override (from an earlier version of this script) on: $dbgov; './edid-8bpc.sh undo' clears it"
    echo "EDID the kernel shows for each monitor:"
    for c in $(nv_connectors); do
        conn=${c##*/card[0-9]-}
        info=$(edid_py info "$c/edid" 2>/dev/null) || info="? ? ?"
        read -r bpc name serial <<< "$info"
        printf '  %-6s %-14s serial %-10s %s bpc\n' "$conn" "$name" "$serial" "$bpc"
    done
    echo "What NVIDIA sends (30bpp = 10 bits per colour, 24bpp = 8):"
    "$NV_HEADS" 2>&1 | sed 's/^/  /'
}

cmd_try() {
    local conn file entry rt value keep=() new=() names=" $* "
    [ $# -gt 0 ] || die "usage: ./edid-8bpc.sh try DP-2 [DP-3]"
    in_session
    [ -n "$DRYRUN" ] || sudo -v || die "needs sudo"
    [ -e "$PARAM" ] || die "$PARAM is missing (kernel without CONFIG_DRM_LOAD_EDID_FIRMWARE?)"
    check_tools
    backup_kwin_config
    srun mkdir -p "$FWDIR"
    for conn in "$@"; do
        file=$(build "$conn")
        srun install -m 0644 "$file" "$FWDIR/${file##*/}"
        new+=("$conn:edid/${file##*/}")
    done
    # keep entries for other connectors already set (from an earlier try, or the boot setting)
    rt=$(runtime_value)
    for entry in ${rt//,/ }; do
        case $entry in *:*) case $names in *" ${entry%%:*} "*) ;; *) keep+=("$entry") ;; esac ;; esac
    done
    value=$(IFS=,; echo "${keep[*]}${keep[*]:+,}${new[*]}")
    log "Override until reboot: $value"
    if [ -n "$DRYRUN" ]; then echo "[dry-run] write '$value' to $PARAM"; else printf '%s' "$value" | sudo tee "$PARAM" >/dev/null; fi
    for conn in "$@"; do apply "$conn"; done
    echo
    echo "Expect 24bpp above. If it still says 30bpp, see TESTBED.md (Phase S, step 4). Go back with ./edid-8bpc.sh undo (or reboot)."
}

cmd_undo() {
    local conns dbg conn
    in_session
    [ -n "$DRYRUN" ] || sudo -v || die "needs sudo"
    conns=$(overridden | sort -u | paste -sd' ')
    [ -n "$conns" ] || { echo "nothing to undo: no 8 bpc override active"; return; }
    if [ -n "$DRYRUN" ]; then echo "[dry-run] write '$CLEARED' to $PARAM"; else printf '%s' "$CLEARED" | sudo tee "$PARAM" >/dev/null; fi
    if dbg=$(dri_debugfs); then
        for conn in $(debugfs_overrides); do
            if [ -n "$DRYRUN" ]; then echo "[dry-run] printf reset > $dbg/$conn/edid_override"; else printf reset | sudo tee "$dbg/$conn/edid_override" >/dev/null; fi
        done
    fi
    for conn in $conns; do apply "$conn"; done
    echo "back to the monitors' own EDIDs (expect 30bpp above)."
}

nvidia_in_initramfs() { [ "$(sudo lsinitrd 2>/dev/null | grep -c 'nvidia-drm\.ko' || true)" -gt 0 ]; }

cmd_boot() {
    local conn file arg='' files=()
    [ $# -gt 0 ] || die "usage: ./edid-8bpc.sh boot DP-2 [DP-3]"
    require_fedora
    [ -r "$KCONFIG" ] && ! grep -q '^CONFIG_DRM_LOAD_EDID_FIRMWARE=y' "$KCONFIG" && die "this kernel can't load EDID files"
    check_tools
    backup_kwin_config
    srun mkdir -p "$FWDIR"
    for conn in "$@"; do
        file=$(build "$conn")
        srun install -m 0644 "$file" "$FWDIR/${file##*/}"
        files+=("$FWDIR/${file##*/}")
        arg="${arg:+$arg,}$conn:edid/${file##*/}"
    done
    log "Kernel argument drm.edid_firmware=$arg"
    srun grubby --update-kernel=ALL --remove-args=drm.edid_firmware
    srun grubby --update-kernel=ALL --args="drm.edid_firmware=$arg"
    if nvidia_in_initramfs; then
        log "nvidia-drm loads from the initramfs here: adding the EDID files there"
        write_root_file "$DRACUT_CONF" <<< "install_items+=\" ${files[*]} \""
        srun dracut -f
    fi
    echo "Reboot to apply, then check with ./edid-8bpc.sh status (expect 24bpp for $*)."
}

cmd_boot_off() {
    require_fedora
    srun grubby --update-kernel=ALL --remove-args=drm.edid_firmware
    if [ -e "$DRACUT_CONF" ]; then
        srun rm -f "$DRACUT_CONF"
        srun dracut -f
    fi
    srun sh -c "rm -f '$FWDIR'/$PREFIX-*.bin"
    echo "Reboot to go back to the monitors' own EDIDs."
}

case ${1:-} in
    status) cmd_status ;;
    try) shift; cmd_try "$@" ;;
    undo) cmd_undo ;;
    boot) shift; cmd_boot "$@" ;;
    boot-off) cmd_boot_off ;;
    *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
