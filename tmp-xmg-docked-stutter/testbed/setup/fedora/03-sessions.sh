#!/bin/bash
# Optional: add COSMIC and GNOME sessions for comparison runs, keeping the
# current (Plasma) login manager as the active one.
#   ./03-sessions.sh [cosmic] [gnome]      (default: both; DRYRUN=1 to preview)
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
require_fedora

want=("$@"); [ ${#want[@]} -gt 0 ] || want=(cosmic gnome)
dm=$(systemctl show -p Id --value display-manager.service 2>/dev/null || true)
log "Current login manager: ${dm:-unknown}"

for w in "${want[@]}"; do
    case $w in
        cosmic) log "Installing COSMIC"; srun dnf install -y @cosmic-desktop-environment ;;
        gnome) log "Installing GNOME"; srun dnf group install -y gnome-desktop ;;
        *) die "unknown session '$w' (cosmic, gnome)" ;;
    esac
done

if [ -n "$dm" ]; then
    log "Keeping $dm as the login manager"
    for other in gdm.service cosmic-greeter.service; do
        [ "$other" = "$dm" ] || srun systemctl disable "$other" 2>/dev/null || true
    done
    srun systemctl enable --force "$dm"
fi
log "Done. Pick the session on the login screen. COSMIC has no KWin frame log: judge it by feel, optionally with 'stuttertest run NAME --smi'."
