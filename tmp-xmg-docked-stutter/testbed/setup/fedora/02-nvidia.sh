#!/bin/bash
# Fedora test bed, step 2: install or switch the NVIDIA driver (RPM Fusion akmods).
#
#   ./02-nvidia.sh open                 current branch (615.x), open kernel modules (GSP always on)
#   ./02-nvidia.sh closed               same driver version, proprietary kernel modules, GSP on
#   ./02-nvidia.sh closed-gsp-off       proprietary kernel modules with GSP firmware disabled
#   ./02-nvidia.sh legacy-open          580xx branch (580.178.04), open modules
#   ./02-nvidia.sh legacy-closed        580xx branch, proprietary modules, GSP on
#   ./02-nvidia.sh legacy-closed-gsp-off
#   ./02-nvidia.sh status               what is installed, built and loaded
#
# Each switch rebuilds the kernel module for the running and the newest installed
# kernel, verifies it, and asks for a reboot. DRYRUN=1 previews the commands.
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"

MACROS=$ETC/rpm/macros.nvidia-kmod
GSPCONF=$ETC/modprobe.d/zz-nvidia-gsp.conf
AKMODS_KEY=$ETC/pki/akmods/certs/public_key.der

usage() { sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

status() {
    log "Installed NVIDIA packages"
    rpm -qa 2>/dev/null | grep -E '^(akmod-nvidia|kmod-nvidia|xorg-x11-drv-nvidia|nvidia-)' | sort || true
    log "Build settings"
    echo "$MACROS: $(cat "$MACROS" 2>/dev/null || echo '(none: RPM Fusion auto-detect, open modules on RTX 40)')"
    echo "$GSPCONF: $(cat "$GSPCONF" 2>/dev/null || echo '(none: GSP on)')"
    log "Built modules"
    local k
    for k in $(kernels); do
        printf '%s: %s %s\n' "$k" "$(modinfo -k "$k" -F version nvidia 2>/dev/null || echo 'not built')" \
            "$(license_kind "$(modinfo -k "$k" -F license nvidia 2>/dev/null)")"
    done
    log "Loaded driver"
    head -1 /proc/driver/nvidia/version 2>/dev/null || echo "nvidia module not loaded"
    nvidia-smi -q 2>/dev/null | grep -iE 'Driver Version|GSP Firmware' || true
    grep -E 'EnableGpuFirmware|DynamicPowerManagement|UseKernelSuspendNotifiers' /proc/driver/nvidia/params 2>/dev/null || true
    if command -v mokutil >/dev/null; then mokutil --sb-state 2>/dev/null || true; fi
}

license_kind() { case $1 in NVIDIA) echo "(proprietary)" ;; '') echo "" ;; *) echo "(open)" ;; esac; }

# Running kernel plus the newest installed one, without duplicates.
kernels() {
    local running newest
    running=$(uname -r)
    local moddir=${SETUP_MODULES:-/lib/modules}
    newest=$(find "$moddir" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -V | tail -1)
    echo "$running"
    if [ -n "$newest" ] && [ "$newest" != "$running" ] && [ -d "$moddir/$newest/build" ]; then echo "$newest"; fi
}

check_secure_boot() {
    command -v mokutil >/dev/null || return 0
    mokutil --sb-state 2>/dev/null | grep -qi enabled || return 0
    if [ -e "$AKMODS_KEY" ] && mokutil --test-key "$AKMODS_KEY" 2>/dev/null | grep -qi 'already enrolled'; then
        return 0
    fi
    cat <<EOT

Secure Boot is on, and the akmods signing key is not enrolled yet, so a freshly
built NVIDIA module would be refused at boot. Either turn Secure Boot off in the
BIOS (simplest for a test bed), or enroll the key once:

    sudo dnf install -y akmods kmodtool mokutil openssl
    sudo kmodgenca -a
    sudo mokutil --import $AKMODS_KEY      # choose a one-time password
    reboot                                  # blue MOK screen: Enroll MOK > Continue > Yes > password

Then run this script again.
EOT
    [ -n "$DRYRUN" ] || exit 1
}

mode=${1:-}
case $mode in
    status) status; exit 0 ;;
    open|closed|closed-gsp-off|legacy-open|legacy-closed|legacy-closed-gsp-off) ;;
    *) usage ;;
esac

require_fedora
check_secure_boot

case $mode in
    legacy-*) PKGS=(akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx-cuda xorg-x11-drv-nvidia-580xx-cuda-libs); branch=580xx ;;
    *) PKGS=(akmod-nvidia xorg-x11-drv-nvidia-cuda xorg-x11-drv-nvidia-cuda-libs); branch=current ;;
esac
case $mode in
    *open) kind=open; macro='%_with_kmod_nvidia_open 1'; want_license=open ;;
    *) kind=proprietary; macro='%_without_kmod_nvidia_detect 1'; want_license=proprietary ;;
esac
gsp_off=; case $mode in *-gsp-off) gsp_off=1 ;; esac

log "Driver: $branch branch, $kind kernel modules, GSP ${gsp_off:+off}${gsp_off:-on}"

log "Kernel module type for akmods ($MACROS)"
write_root_file "$MACROS" <<< "$macro"

log "GSP firmware setting ($GSPCONF)"
if [ -n "$gsp_off" ]; then
    write_root_file "$GSPCONF" <<< "options nvidia NVreg_EnableGpuFirmware=0"
else
    srun rm -f "$GSPCONF"
fi

log "Installing packages (switching branch if needed)"
srun dnf install -y --allowerasing "${PKGS[@]}"

log "Building the kernel module"
for k in $(kernels); do
    srun akmods --force --rebuild --kernels "$k"
    srun dracut -f --kver "$k"
    if [ -z "$DRYRUN" ]; then
        ver=$(modinfo -k "$k" -F version nvidia 2>/dev/null || true)
        lic=$(modinfo -k "$k" -F license nvidia 2>/dev/null || true)
        got=open; [ "$lic" = NVIDIA ] && got=proprietary
        [ -n "$ver" ] || die "no nvidia module was built for $k (see: journalctl -u akmods, /var/cache/akmods/nvidia/*.log)"
        [ "$got" = "$want_license" ] || die "built $got modules for $k, expected $want_license (check $MACROS)"
        echo "$k: nvidia $ver ($got)"
    fi
done

log "Done. Reboot, then check with: ./02-nvidia.sh status"
if [ -n "$gsp_off" ]; then echo "After the reboot, 'GSP Firmware Version' must read N/A."; fi
