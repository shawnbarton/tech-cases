#!/bin/bash
# Fedora KDE test bed, step 1: update, RPM Fusion, diagnostic tools, full Intel media driver.
#   ./01-base.sh            (DRYRUN=1 ./01-base.sh to preview)
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
require_fedora
[ "${FEDORA%%.*}" -ge 44 ] 2>/dev/null || warn "this plan was written for Fedora 44 (found $FEDORA)"

log "Updating the system"
srun dnf upgrade --refresh -y

log "Enabling RPM Fusion (free and nonfree)"
if rpm -q rpmfusion-free-release rpmfusion-nonfree-release >/dev/null 2>&1; then
    echo "already enabled"
else
    srun dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$FEDORA.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$FEDORA.noarch.rpm"
fi

log "Installing diagnostic tools"
TOOLS=(glx-utils mesa-demos vulkan-tools igt-gpu-tools libva-utils drm_info edid-decode
       python3 pciutils lm_sensors bolt switcheroo-control mokutil git dbus-tools mpv xlsclients)
srun dnf install -y --skip-unavailable "${TOOLS[@]}"
# Full-feature Intel media driver from RPM Fusion nonfree: Fedora's own build has no AV1 decode on Raptor Lake.
srun dnf install -y intel-media-driver
srun systemctl enable --now switcheroo-control.service

if [ -z "$DRYRUN" ]; then
    missing=()
    for p in "${TOOLS[@]}" intel-media-driver; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
    [ ${#missing[@]} -eq 0 ] || warn "not installed (not in the repos under that name): ${missing[*]}"
    command -v glxgears >/dev/null || warn "glxgears not found (needed for the forced-P0 test)"
    command -v kscreen-doctor >/dev/null || warn "kscreen-doctor not found (normally part of Plasma)"
fi

log "Emergency keys: allow Alt+SysRq sync (S), remount read-only (U) and reboot (B)"
# Fedora allows only sync by default; 176 = 16 + 32 + 128, the same set Ubuntu allows.
write_root_file "$ETC/sysctl.d/90-sysrq-recovery.conf" <<< "kernel.sysrq = 176"
srun sysctl -q --system

log "Checks"
if command -v mokutil >/dev/null; then
    mokutil --sb-state 2>/dev/null || true
    echo "Secure Boot on means the NVIDIA modules must be signed: 02-nvidia.sh explains the one-time key enrollment."
fi
echo "CPU microcode: $(grep -m1 microcode /proc/cpuinfo | sed 's/.*: //') (newest for this CPU, 06-b7-01, is 0x137)"
if command -v boltctl >/dev/null; then
    boltctl list 2>/dev/null | grep -E 'name|status|uuid' || true
    echo "If the dock shows as unauthorized: boltctl enroll --policy auto <uuid>"
fi

log "Done. Reboot if the kernel was updated, then run: ./02-nvidia.sh 580-open"
