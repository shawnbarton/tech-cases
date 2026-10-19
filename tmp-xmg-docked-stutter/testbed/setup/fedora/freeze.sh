#!/bin/bash
# Freeze the software stack for the test campaign with dnf versionlock, so an
# update can't change KWin, Plasma, Qt, Mesa, Xwayland, the kernel or the NVIDIA
# driver between phases. 02-nvidia.sh unlocks and relocks the NVIDIA packages
# around its own driver switches.
#   ./freeze.sh on | off | status          (DRYRUN=1 to preview)
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
MARKER=$ETC/xmg-testbed-freeze
STACK=('kwin*' 'plasma-*' 'kf6-*' 'qt6-*' 'kernel*' 'mesa-*' xorg-x11-server-Xwayland)
NVIDIA=('akmod-nvidia*' 'kmod-nvidia*' 'xorg-x11-drv-nvidia*' 'nvidia-settings*')

case ${1:-} in
    on)
        srun dnf versionlock add "${STACK[@]}" "${NVIDIA[@]}"
        write_root_file "$MARKER" <<< "frozen $(date -Is)"
        echo "frozen; undo after the campaign with: ./freeze.sh off" ;;
    off)
        srun dnf versionlock clear
        srun rm -f "$MARKER"
        echo "unfrozen; updates apply normally again" ;;
    status)
        if [ -e "$MARKER" ]; then cat "$MARKER"; else echo "not frozen"; fi
        dnf versionlock list 2>/dev/null || true ;;
    unlock-nvidia)
        [ -e "$MARKER" ] || exit 0
        srun dnf versionlock delete "${NVIDIA[@]}" ;;
    relock-nvidia)
        [ -e "$MARKER" ] || exit 0
        srun dnf versionlock add "${NVIDIA[@]}" ;;
    *) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
