#!/bin/bash
# Install the test tools for the current user and prepare the Plasma session for
# measurements. Works on any distro. Run it inside the Plasma session, docked,
# with both external monitors on.
#   ./install-testbed.sh          (DRYRUN=1 to preview)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TB=$(cd "$HERE/.." && pwd)
BIN=$HOME/.local/bin
DRYRUN=${DRYRUN:-}
run() { if [ -n "$DRYRUN" ]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }
log() { printf '\n==> %s\n' "$*"; }
NV_PCI=0000:01:00.0

# SETUP_ALLOW_ROOT exists for the test suite only.
[ "$(id -u)" != 0 ] || [ -n "${SETUP_ALLOW_ROOT:-}" ] || { echo "run as your normal user" >&2; exit 1; }

log "Linking tools into $BIN"
run mkdir -p "$BIN"
for t in stuttertest kwin-perf-summary stutter-analyze nv-heads nv-powermizer dgpu-run; do
    run ln -sfn "$TB/bin/$t" "$BIN/$t"
done
case ":$PATH:" in *":$BIN:"*) ;; *) echo "note: $BIN is not in PATH yet; open a new terminal or log out and in" ;; esac

log "Menu entry for marking static during a run (give it a keyboard shortcut)"
APPS=$HOME/.local/share/applications
run mkdir -p "$APPS"
if [ -z "$DRYRUN" ]; then
    cat > "$APPS/stuttertest-mark.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Stuttertest: mark static
Comment=Records the moment you saw static or blanking, for the running stuttertest
Exec=$BIN/stuttertest mark shortcut
Icon=dialog-warning
Terminal=false
Categories=Utility;
EOF
else
    echo "[dry-run] write $APPS/stuttertest-mark.desktop"
fi
echo "Bind it once: System Settings > Keyboard > Shortcuts > Add New > Application >"
echo "'Stuttertest: mark static', then pick a key such as Meta+Ctrl+M."

log "Installing the KWin login script with frame logging on"
run "$TB/bin/stuttertest" kwin install
run "$TB/bin/stuttertest" kwin set perf=on >/dev/null

log "Adaptive Sync: Never on the monitors driven by the NVIDIA GPU"
outputs=()
for c in /sys/bus/pci/devices/"$NV_PCI"/drm/card*/card*-*; do
    [ -r "$c/status" ] || continue
    name=${c##*/}; name=${name#card*-}
    case $name in eDP-*|LVDS-*|DSI-*) continue ;; esac
    [ "$(cat "$c/status")" = connected ] && outputs+=("$name")
done
if [ ${#outputs[@]} -eq 0 ]; then
    echo "no external monitor connected on the NVIDIA GPU: dock first, then re-run this step"
elif ! command -v kscreen-doctor >/dev/null || [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "run inside the Plasma session to set it; outputs: ${outputs[*]}"
else
    args=()
    for o in "${outputs[@]}"; do args+=("output.$o.vrrpolicy.never"); done
    run kscreen-doctor "${args[@]}" || echo "kscreen-doctor failed; set Adaptive Sync to Never in Display settings for: ${outputs[*]}"
fi

log "Power profile: balanced, kept fixed for the whole test campaign"
# Works with both power-profiles-daemon and Fedora's tuned-ppd (same D-Bus API).
PPD=(net.hadess.PowerProfiles /net/hadess/PowerProfiles net.hadess.PowerProfiles ActiveProfile)
if run busctl --system set-property "${PPD[@]}" s balanced 2>/dev/null; then
    echo "current: $(busctl --system get-property "${PPD[@]}" 2>/dev/null | cut -d'"' -f2)"
else
    echo "could not set it: choose Balanced in the battery applet"
fi

log "No automatic screen dimming, screen-off, sleep or screen lock on AC power"
# Screen-off and lock power-cycle the docked monitors, which is exactly the
# hotplug path that can hang KWin on driver 615 (open-gpu-kernel-modules #1392).
if command -v kwriteconfig6 >/dev/null; then
    run kwriteconfig6 --file powerdevilrc --group AC --group Display --key DimDisplayWhenIdle false
    run kwriteconfig6 --file powerdevilrc --group AC --group Display --key TurnOffDisplayWhenIdle false
    run kwriteconfig6 --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendAction 0
    run kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock false
    echo "takes effect at the next login; undo later in System Settings > Power Management and > Screen Locking"
else
    echo "kwriteconfig6 not found: set Dim, Turn off screen and Sleep to Never (on AC) and screen locking off by hand"
fi

log "Lid"
echo "Keep one lid state for the whole campaign. If you work lid-open with the built-in"
echo "display disabled, run once: stuttertest kwin set lidcheck=off"
echo "(otherwise 'gpu=nvidia' is skipped while the lid is open)."

log "GPU pollers (they can add stutter on GSP drivers; keep them closed while testing)"
pgrep -a -f 'nvtop|mangohud|gwe|coolercontrol|tuxedo-control-center' | grep -v pgrep || echo "none running"

log "Done. Log out and back in docked, then: stuttertest info"
