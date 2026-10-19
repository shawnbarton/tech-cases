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
for t in stuttertest kwin-perf-summary nv-powermizer dgpu-run; do
    run ln -sfn "$TB/bin/$t" "$BIN/$t"
done
case ":$PATH:" in *":$BIN:"*) ;; *) echo "note: $BIN is not in PATH yet; open a new terminal or log out and in" ;; esac

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
if command -v powerprofilesctl >/dev/null; then
    run powerprofilesctl set balanced || true
    echo "current: $(powerprofilesctl get 2>/dev/null || echo '?')"
fi

log "GPU pollers (they can add stutter on GSP drivers; keep them closed while testing)"
pgrep -a -f 'nvtop|mangohud|gwe|coolercontrol|tuxedo-control-center' | grep -v pgrep || echo "none running"

log "Done. Log out and back in docked, then: stuttertest info"
