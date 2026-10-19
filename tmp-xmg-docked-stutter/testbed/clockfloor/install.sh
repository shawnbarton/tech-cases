#!/bin/bash
# Install or remove the NVIDIA clock lock service.
#   sudo ./install.sh              install and start
#   sudo ./install.sh --uninstall  stop, reset clocks, remove (keeps /etc/default/nvidia-clockfloor)
#   sudo ./install.sh --purge      same, and remove the config
set -eu
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

UNITS="nvidia-clockfloor.service nvidia-clockfloor.timer nvidia-clockfloor-resume.service"

uninstall() {
    # Stop every trigger first so nothing re-applies a lock after the reset.
    rm -f /etc/udev/rules.d/99-nvidia-clockfloor.rules
    udevadm control --reload || true
    systemctl disable --now nvidia-clockfloor.timer nvidia-clockfloor-resume.service 2>/dev/null || true
    systemctl stop nvidia-clockfloor.service 2>/dev/null || true
    if [ -e /run/nvidia-clockfloor.state ]; then
        timeout 30 nvidia-smi -rmc >/dev/null 2>&1 || true
        timeout 30 nvidia-smi -rgc >/dev/null 2>&1 || true
        if [ -x /usr/local/sbin/nv-powermizer ]; then
            timeout 30 /usr/local/sbin/nv-powermizer adaptive >/dev/null 2>&1 || true
        fi
    fi
    for u in $UNITS; do rm -f "/etc/systemd/system/$u"; done
    rm -f /usr/local/sbin/nvidia-clockfloor /usr/local/sbin/nv-powermizer
    rm -f /run/nvidia-clockfloor.state /run/nvidia-clockfloor.stale /run/nvidia-clockfloor.lock
    systemctl daemon-reload
    systemctl reset-failed nvidia-clockfloor.service 2>/dev/null || true
    echo "removed"
}

case ${1:-} in
    --uninstall) uninstall; exit 0 ;;
    --purge) uninstall; rm -f /etc/default/nvidia-clockfloor; exit 0 ;;
    "") ;;
    *) echo "usage: $0 [--uninstall|--purge]"; exit 2 ;;
esac

install -m 0755 nvidia-clockfloor ../bin/nv-powermizer /usr/local/sbin/
if [ ! -e /etc/default/nvidia-clockfloor ]; then
    install -m 0644 nvidia-clockfloor.conf /etc/default/nvidia-clockfloor
elif ! cmp -s nvidia-clockfloor.conf /etc/default/nvidia-clockfloor; then
    echo "note: keeping your existing /etc/default/nvidia-clockfloor (edit that file, not the copy here)"
fi
for u in $UNITS; do install -m 0644 "$u" /etc/systemd/system/; done
install -m 0644 99-nvidia-clockfloor.rules /etc/udev/rules.d/
systemctl daemon-reload
systemctl enable --now nvidia-clockfloor.timer
systemctl enable nvidia-clockfloor-resume.service
udevadm control --reload
systemctl start nvidia-clockfloor.service || true
echo "installed; settings: /etc/default/nvidia-clockfloor; log: journalctl -t nvidia-clockfloor -b"
