#!/bin/bash
# Make a monitor's EDID say 8 bits per colour, to test whether the dock-port static
# comes from running the DisplayPort link at 10 bpc (Windows uses 8 there).
#
#   ./edid-8bpc.sh status              what each monitor on the NVIDIA GPU reports now
#   ./edid-8bpc.sh try DP-2 [DP-3]     until reboot (kernel debugfs override); then power-cycle
#                                      that monitor with its button so the link is set up again
#   ./edid-8bpc.sh undo                remove those overrides; power-cycle the monitor(s) again
#   ./edid-8bpc.sh boot DP-2 [DP-3]    from every boot on (drm.edid_firmware); then reboot
#   ./edid-8bpc.sh boot-off            remove the boot setting; then reboot
#
# Why it works with NVIDIA: nvidia-drm hands an override EDID from the kernel to NVKMS
# (nvidia-drm-connector.c, overrideEdid), and NVKMS caps a DP link's colour depth at the
# EDID's bits per colour (nvkms-dpy.c, nvDpyGetOutputColorFormatInfo).
# Only byte 20 (bits 6-4) and the block checksum change; edid-decode checks the result.
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"

NV_PCI=0000:01:00.0
# SETUP_SYS / SETUP_DEBUGFS / SETUP_FIRMWARE / SETUP_CMDLINE / SETUP_KCONFIG exist for the test suite only.
SYS=${SETUP_SYS:-/sys}
DEBUGFS=${SETUP_DEBUGFS:-/sys/kernel/debug}
FWDIR=${SETUP_FIRMWARE:-/usr/lib/firmware}/edid
CMDLINE=${SETUP_CMDLINE:-/proc/cmdline}
KCONFIG=${SETUP_KCONFIG:-/lib/modules/$(uname -r)/config}
DRACUT_CONF=$ETC/dracut.conf.d/90-xmg-edid-8bpc.conf
WORK=${XDG_STATE_HOME:-$HOME/.local/state}/xmg-edid
PREFIX=xmg-8bpc

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
e[20] = (e[20] & 0x8F) | (2 << 4)
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
    for c in $(nv_connectors); do [ "${c##*/card[0-9]-}" = "$1" ] && { echo "$c"; return; }; done
    for c in "$SYS"/bus/pci/devices/"$NV_PCI"/drm/card*/card*-"$1"; do [ -e "$c" ] && { echo "$c"; return; }; done
    return 1
}
# The NVIDIA GPU's DRM debugfs directory (root-only); its 'name' file names the PCI device.
dri_debugfs() {
    local d
    for d in $(sudo sh -c "ls -d '$DEBUGFS'/dri/*/ 2>/dev/null"); do
        sudo grep -qs "$NV_PCI" "$d/name" && { echo "${d%/}"; return; }
    done
    return 1
}
check_tools() { command -v edid-decode >/dev/null || warn "edid-decode is missing (01-base.sh installs it); skipping the conformity check"; }

# Build the 8 bpc copy of CONNECTOR's current EDID in $WORK, keep the original once, check it.
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

cmd_status() {
    local c conn info bpc name serial dbg='' ov boot
    [ -r "$KCONFIG" ] && { grep -q '^CONFIG_DRM_LOAD_EDID_FIRMWARE=y' "$KCONFIG" && echo "kernel: loads EDID files at boot (drm.edid_firmware works)" || echo "kernel: CONFIG_DRM_LOAD_EDID_FIRMWARE is off; only 'try' works"; }
    boot=$(tr ' ' '\n' < "$CMDLINE" | grep '^drm.edid_firmware=' || true)
    echo "boot setting: ${boot:-none}"
    dbg=$(dri_debugfs 2>/dev/null) || dbg=''
    for c in $(nv_connectors); do
        conn=${c##*/card[0-9]-}
        info=$(edid_py info "$c/edid" 2>/dev/null) || info="? ? ?"
        read -r bpc name serial <<< "$info"
        ov=no
        [ -n "$dbg" ] && [ "$(sudo cat "$dbg/$conn/edid_override" 2>/dev/null | wc -c)" -gt 0 ] && ov=yes
        printf '%-6s %-14s serial %-10s EDID bpc %-3s runtime override: %s\n' "$conn" "$name" "$serial" "$bpc" "$ov"
    done
}

cmd_try() {
    local conn file dbg
    [ $# -gt 0 ] || die "usage: ./edid-8bpc.sh try DP-2 [DP-3]"
    check_tools
    dbg=$(dri_debugfs) || die "can't find the NVIDIA GPU under $DEBUGFS/dri (is debugfs mounted?)"
    for conn in "$@"; do
        file=$(build "$conn")
        sudo test -e "$dbg/$conn/edid_override" || die "$dbg/$conn/edid_override doesn't exist"
        if [ -n "$DRYRUN" ]; then echo "[dry-run] write $file to $dbg/$conn/edid_override"; else sudo tee "$dbg/$conn/edid_override" < "$file" >/dev/null; fi
        srun sh -c "echo detect > '$(conn_dir "$conn")/status'"
    done
    echo
    echo "Now turn the monitor(s) on $* off with the power button, wait 5 s, and turn them on again."
    echo "That makes the driver set the link up again with the new EDID. Then check: ./edid-8bpc.sh status"
    echo "It lasts until reboot; './edid-8bpc.sh undo' and another power-cycle go back."
}

cmd_undo() {
    local dbg c conn any=''
    dbg=$(dri_debugfs) || die "can't find the NVIDIA GPU under $DEBUGFS/dri"
    for c in $(nv_connectors); do
        conn=${c##*/card[0-9]-}
        [ "$(sudo cat "$dbg/$conn/edid_override" 2>/dev/null | wc -c)" -gt 0 ] || continue
        if [ -n "$DRYRUN" ]; then echo "[dry-run] write reset to $dbg/$conn/edid_override"; else echo reset | sudo tee "$dbg/$conn/edid_override" >/dev/null; fi
        srun sh -c "echo detect > '$c/status'"
        any="$any $conn"
    done
    [ -n "$any" ] || { echo "no runtime override active"; return; }
    echo "removed on:$any. Power-cycle those monitor(s) with their button to go back to the monitor's own EDID."
}

nvidia_in_initramfs() { [ "$(sudo lsinitrd 2>/dev/null | grep -c 'nvidia-drm\.ko' || true)" -gt 0 ]; }

cmd_boot() {
    local conn file arg='' files=()
    [ $# -gt 0 ] || die "usage: ./edid-8bpc.sh boot DP-2 [DP-3]"
    require_fedora
    [ -r "$KCONFIG" ] && ! grep -q '^CONFIG_DRM_LOAD_EDID_FIRMWARE=y' "$KCONFIG" && die "this kernel can't load EDID files at boot; use 'try'"
    check_tools
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
        log "nvidia-drm loads from the initramfs: adding the EDID files there"
        write_root_file "$DRACUT_CONF" <<< "install_items+=\" ${files[*]} \""
        srun dracut -f
    fi
    echo "Reboot to apply. './edid-8bpc.sh status' then shows 8 bpc for $*."
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
    *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
