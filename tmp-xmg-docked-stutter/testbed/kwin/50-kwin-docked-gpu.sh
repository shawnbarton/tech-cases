# KWin settings for the XMG Fusion 15 (E24) while docked: optionally composite
# on NVIDIA and/or force triple buffering on or off for the NVIDIA-driven outputs.
# Managed by "stuttertest kwin set ..."; editing by hand works too.
# Undocked (no DP/HDMI connected on the NVIDIA card) it changes nothing.
#
# Install: copy to ~/.config/plasma-workspace/env/ and log out and back in.
# Plasma sources this file with /bin/sh before KWin starts, so it must stay
# POSIX sh, print nothing and never call exit. KWin only reads these settings
# at login: log out and back in after docking or undocking.
#
# Recovery if a docked login breaks: unplug the dock, log in (this file then
# does nothing), and move this file out of ~/.config/plasma-workspace/env/.

# nvidia = KWin composites on NVIDIA while docked. Empty = KWin default (Intel).
KD_GPU=

# Only switch to NVIDIA when the lid is closed at login. With KWin 6.6 on NVIDIA,
# a lit internal panel is fed by a slow copy that stalls the Dells too.
# Set empty only after disabling eDP-1 in Display settings while docked WITH THE
# LID OPEN (KWin stores lid-open and lid-closed layouts separately).
KD_REQUIRE_LID_CLOSED=1

# Triple buffering on outputs driven by the NVIDIA GPU (the Dells) while docked:
# 1 = force on, 0 = force off, empty = KWin default (off on NVIDIA before 6.7.3,
# on from 6.7.3). It only engages with Adaptive Sync set to Never.
KD_TRIPLE_BUFFERING=

# KWin's safety margin before each vblank, in microseconds (KWin default 1000).
# Raising it (e.g. 3000) gives slow commits more time. Empty = KWin default.
KD_SAFETY_MARGIN=

# 1 = write per-output frame timing CSVs ("kwin perf statistics <output>.csv")
# to the home directory for kwin-perf-summary. KWin overwrites them at each login.
KD_PERF_LOG=

# Plasma copies the session environment into the systemd user manager, so a value
# removed here could survive from an earlier login. Clear what this file manages.
systemctl --user unset-environment KWIN_DRM_DEVICES KWIN_DRM_DISABLE_TRIPLE_BUFFERING \
    KWIN_DRM_OVERRIDE_SAFETY_MARGIN KWIN_LOG_PERFORMANCE_DATA >/dev/null 2>&1

kd_nv=/dev/dri/by-path/pci-0000:01:00.0-card
kd_ig=/dev/dri/by-path/pci-0000:00:02.0-card
kd_docked=
if [ -e "$kd_nv" ]; then
    kd_card=$(basename "$(readlink -f "$kd_nv")")
    for kd_s in /sys/class/drm/"$kd_card"-DP-*/status /sys/class/drm/"$kd_card"-HDMI-A-*/status; do
        if [ -r "$kd_s" ] && [ "$(cat "$kd_s")" = connected ]; then
            kd_docked=1
            break
        fi
    done
fi

if [ -n "$kd_docked" ] && [ "$KD_GPU" = nvidia ] && [ -e "$kd_ig" ]; then
    kd_ok=1
    # Kernel module and userspace driver must match (after a driver update
    # without a reboot they don't, and KWin would fall back to software rendering).
    kd_ver=$(cat /sys/module/nvidia/version 2>/dev/null)
    kd_lib=
    for kd_l in /usr/lib/libnvidia-eglcore.so."$kd_ver" /usr/lib64/libnvidia-eglcore.so."$kd_ver" /usr/lib/*/libnvidia-eglcore.so."$kd_ver"; do
        [ -n "$kd_ver" ] && [ -e "$kd_l" ] && kd_lib=1
    done
    [ -n "$kd_lib" ] || kd_ok=
    if [ "$KD_REQUIRE_LID_CLOSED" = 1 ] && grep -qs open /proc/acpi/button/lid/*/state; then
        kd_ok=
    fi
    if [ -n "$kd_ok" ]; then
        # First entry = compositing GPU. Resolved to /dev/dri/cardN at every login:
        # no ':' to escape (KWin splits this list on ':'), and no by-path symlinks,
        # which KWin 6.8.0 fails to re-open after suspend (KDE bug 527309).
        kd_list="$(readlink -f "$kd_nv"):$(readlink -f "$kd_ig")"
        export KWIN_DRM_DEVICES="$kd_list"
    fi
fi

if [ -n "$kd_docked" ]; then
    case $KD_TRIPLE_BUFFERING in
        1) export KWIN_DRM_DISABLE_TRIPLE_BUFFERING=0 ;;
        0) export KWIN_DRM_DISABLE_TRIPLE_BUFFERING=1 ;;
    esac
fi

case $KD_SAFETY_MARGIN in
    ''|*[!0-9]*) ;;
    *) if [ -n "$kd_docked" ]; then export KWIN_DRM_OVERRIDE_SAFETY_MARGIN="$KD_SAFETY_MARGIN"; fi ;;
esac

if [ "$KD_PERF_LOG" = 1 ]; then
    export KWIN_LOG_PERFORMANCE_DATA=1
fi

unset kd_nv kd_ig kd_card kd_s kd_docked kd_ok kd_ver kd_lib kd_l kd_list KD_GPU KD_REQUIRE_LID_CLOSED KD_TRIPLE_BUFFERING KD_SAFETY_MARGIN KD_PERF_LOG
