#!/bin/bash
# Test the revised 50-kwin-docked-gpu.sh under dash against fake /dev, /sys, /proc and /usr/lib.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TBD=$HERE/../testbed
T=$(mktemp -d "${TMPDIR:-/tmp}/env2.XXXXXX")
mkdir -p "$T/dev/dri/by-path" "$T/sys/class/drm/card1-DP-2" "$T/sys/class/drm/card1-HDMI-A-1" "$T/sys/class/drm/card1-eDP-2" "$T/sys/class/drm/card0-eDP-1" \
         "$T/sys/module/nvidia" "$T/usr/lib/x86_64-linux-gnu" "$T/proc/acpi/button/lid/LID0"
touch "$T/dev/dri/card0" "$T/dev/dri/card1"
ln -s ../card1 "$T/dev/dri/by-path/pci-0000:01:00.0-card"
ln -s ../card0 "$T/dev/dri/by-path/pci-0000:00:02.0-card"
echo connected > "$T/sys/class/drm/card0-eDP-1/status"
echo connected > "$T/sys/class/drm/card1-eDP-2/status"
echo disconnected > "$T/sys/class/drm/card1-HDMI-A-1/status"
echo 595.71.05 > "$T/sys/module/nvidia/version"
touch "$T/usr/lib/x86_64-linux-gnu/libnvidia-eglcore.so.595.71.05"
echo "state:      closed" > "$T/proc/acpi/button/lid/LID0/state"
mk() {
    sed -e "s#/dev/dri/by-path/pci-0000:#$T/dev/dri/by-path/pci-0000:#g" -e "s#/sys/class/drm/#$T/sys/class/drm/#g" \
        -e "s#/sys/module/nvidia/version#$T/sys/module/nvidia/version#" -e "s#/usr/lib/\*/#$T/usr/lib/*/#" \
        -e "s#/proc/acpi/button/lid/#$T/proc/acpi/button/lid/#" \
        -e "s/^KD_GPU=.*/KD_GPU=$1/" -e "s/^KD_TRIPLE_BUFFERING=.*/KD_TRIPLE_BUFFERING=$2/" -e "s/^KD_REQUIRE_LID_CLOSED=.*/KD_REQUIRE_LID_CLOSED=$3/" \
        "$TBD/kwin/50-kwin-docked-gpu.sh" > "$T/env.sh"
}
run() {
    out=$(dash -c "set -u; . '$T/env.sh'; echo \"DEV=[\${KWIN_DRM_DEVICES-unset}] TB=[\${KWIN_DRM_DISABLE_TRIPLE_BUFFERING-unset}] MARGIN=[\${KWIN_DRM_OVERRIDE_SAFETY_MARGIN-unset}] leaked=[\${kd_docked-}\${kd_ok-}\${KD_GPU-}\${KD_SAFETY_MARGIN-}]\"" 2>&1)
    printf '%-52s %s\n' "$1" "$(echo "$out" | sed "s#$T##g")"
}
dock() { echo "$1" > "$T/sys/class/drm/card1-DP-2/status"; }
dock disconnected; mk nvidia 1 1; run "undocked, KD_GPU=nvidia TB=1"
dock connected;    mk "" "" 1;    run "docked, defaults (nothing)"
                   mk "" 1 1;     run "docked, TB forced on (Intel compositing)"
                   mk "" 0 1;     run "docked, TB forced off"
                   mk nvidia "" 1; run "docked, nvidia, lid closed"
echo "state:      open" > "$T/proc/acpi/button/lid/LID0/state"; run "docked, nvidia, lid open -> no switch"
                   mk nvidia "" "";  run "docked, nvidia, lid open, lid check off"
echo "state:      closed" > "$T/proc/acpi/button/lid/LID0/state"
echo 595.84.00 > "$T/sys/module/nvidia/version"; mk nvidia "" 1; run "driver/library mismatch -> no switch"
echo 595.71.05 > "$T/sys/module/nvidia/version"
dock disconnected; echo connected > "$T/sys/class/drm/card1-HDMI-A-1/status"; run "HDMI monitor only -> docked"
unlink "$T/dev/dri/by-path/pci-0000:00:02.0-card"; mk nvidia 1 1; run "BIOS dGPU-only (no iGPU), TB=1"

echo connected > "$T/sys/class/drm/card1-DP-2/status"; ln -s ../card0 "$T/dev/dri/by-path/pci-0000:00:02.0-card"
mk "" "" 1; sed -i 's/^KD_SAFETY_MARGIN=.*/KD_SAFETY_MARGIN=3000/' "$T/env.sh"; run "docked, safety margin 3000"
sed -i 's/^KD_SAFETY_MARGIN=.*/KD_SAFETY_MARGIN=3ms/' "$T/env.sh"; run "docked, invalid margin ignored"
echo disconnected > "$T/sys/class/drm/card1-DP-2/status"; echo disconnected > "$T/sys/class/drm/card1-HDMI-A-1/status"
sed -i 's/^KD_SAFETY_MARGIN=.*/KD_SAFETY_MARGIN=3000/' "$T/env.sh"; run "undocked, margin set -> not applied"
printf '%-52s [%s]\n' "stdout while sourcing (must be empty)" "$(dash -c ". '$T/env.sh'" 2>/dev/null)"
