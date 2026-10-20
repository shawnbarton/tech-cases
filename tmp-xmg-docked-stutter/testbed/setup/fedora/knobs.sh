#!/bin/bash
# Driver-level test knobs (each needs a reboot or takes effect immediately as noted).
#   ./knobs.sh status
#   ./knobs.sh vblank on|off    nvidia_drm vblank=1: flip events carry the real vblank time
#                               (driver 610.43.02+; reboot needed)
#   ./knobs.sh powerd on|off    nvidia-powerd (Dynamic Boost); immediate. Keep it the same across runs.
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
VBLANK=$ETC/modprobe.d/zz-nvidia-drm-vblank.conf

param() {
    local f=/sys/module/nvidia_drm/parameters/$1
    [ -d /sys/module/nvidia_drm ] || { echo unloaded; return; }
    [ -e "$f" ] || { echo "n/a (needs driver 610+)"; return; }
    cat "$f" 2>/dev/null || sudo -n cat "$f" 2>/dev/null || echo root-only
}

case ${1:-}:${2:-} in
    status:)
        echo "nvidia_drm vblank: loaded=$(param vblank)  config=$(cat "$VBLANK" 2>/dev/null || echo none)"
        echo "nvidia-powerd: $(systemctl is-enabled nvidia-powerd.service 2>/dev/null || true) / $(systemctl is-active nvidia-powerd.service 2>/dev/null || true)" ;;
    vblank:on)
        modinfo -F parm nvidia_drm 2>/dev/null | grep -q '^vblank:' || warn "this driver's nvidia_drm has no 'vblank' parameter (needs 610.43.02+)"
        write_root_file "$VBLANK" <<< "options nvidia_drm vblank=1"
        echo "reboot to apply" ;;
    vblank:off)
        srun rm -f "$VBLANK"; echo "reboot to apply" ;;
    powerd:on) srun systemctl enable --now nvidia-powerd.service ;;
    powerd:off) srun systemctl disable --now nvidia-powerd.service ;;
    *) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
