#!/bin/bash
# edid-8bpc.sh against a fake sysfs, debugfs and firmware directory, with a synthetic
# EDID 1.4 that says 10 bpc (like the Dell S2721QS), and fake sudo/grubby/dracut/lsinitrd.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
E=$HERE/../testbed/setup/fedora/edid-8bpc.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/edid.XXXXXX")
NV=$T/sys/bus/pci/devices/0000:01:00.0/drm/card0
mkdir -p "$T/bin" "$T/etc/dracut.conf.d" "$T/fw" "$T/home" "$NV/card0-DP-1" "$NV/card0-DP-2" "$NV/card0-DP-3" \
         "$T/debug/dri/0/DP-2" "$T/debug/dri/0/DP-3" "$T/debug/dri/1"
LOG=$T/calls

python3 - "$NV" <<'PY'
import sys
def edid(serial, bpc_code=3):
    b = bytearray(128)
    b[0:8] = bytes.fromhex("00ffffffffffff00")
    b[8:10] = bytes.fromhex("10ac")                  # DEL
    b[18], b[19] = 1, 4
    b[20] = 0x80 | (bpc_code << 4) | 0x5             # digital, DisplayPort
    def desc(tag, text):
        d = bytearray(18); d[3] = tag
        t = (text + "\n").encode().ljust(13, b" ")[:13]; d[5:18] = t
        return d
    b[54:72] = bytes(18)
    b[72:90] = desc(0xFC, "DELL S2721QS")
    b[90:108] = desc(0xFF, serial)
    b[126] = 1
    b[127] = (-sum(b[:127])) % 256
    ext = bytearray(128); ext[0], ext[1] = 2, 3; ext[127] = (-sum(ext[:127])) % 256
    return bytes(b + ext)
nv = sys.argv[1]
for conn, serial in (("DP-2", "DB70M43"), ("DP-3", "5XD0M43")):
    open(f"{nv}/card0-{conn}/edid", "wb").write(edid(serial))
    open(f"{nv}/card0-{conn}/status", "w").write("connected\n")
open(f"{nv}/card0-DP-1/edid", "wb").write(b"")
open(f"{nv}/card0-DP-1/status", "w").write("disconnected\n")
PY
echo "nvidia-drm dev=0000:01:00.0 unique=0000:01:00.0" > "$T/debug/dri/0/name"
echo "i915 dev=0000:00:02.0 unique=0000:00:02.0" > "$T/debug/dri/1/name"
: > "$T/debug/dri/0/DP-2/edid_override"; : > "$T/debug/dri/0/DP-3/edid_override"
echo "BOOT_IMAGE=/vmlinuz root=UUID=x ro rhgb quiet" > "$T/cmdline"
echo "CONFIG_DRM_LOAD_EDID_FIRMWARE=y" > "$T/kconfig"

cat > "$T/bin/fake" <<EOS
#!/bin/bash
T="$T"; LOG="$LOG"; me=\$(basename "\$0")
case \$me in
  sudo)
    [ "\$1" = -n ] && shift
    case "\$*" in
      *"echo detect >"*) echo "detect \${*##*> }" >> "\$LOG"; exit 0 ;;   # sysfs status write: re-probe
    esac
    if [ "\$1" = tee ]; then
      case "\$2" in */edid_override)
        data=\$(mktemp); cat > "\$data"
        if [ "\$(head -c 6 "\$data" | tr -d "\\0")" = reset ]; then : > "\$2"; echo "override reset \$2" >> "\$LOG"; else cp "\$data" "\$2"; echo "override set \$2 (\$(wc -c < "\$2") bytes)" >> "\$LOG"; fi
        exit 0 ;;
      esac
    fi
    exec "\$@" ;;
  grubby) echo "grubby \$*" >> "\$LOG" ;;
  dracut) echo "dracut \$*" >> "\$LOG" ;;
  lsinitrd) echo "usr/lib/modules/7.2.11-200.fc44.x86_64/extra/nvidia-580xx/nvidia-drm.ko.xz" ;;
  edid-decode)
    [ "\$1" = --check ] && { shift; exit 0; }
    python3 -c 'import sys; b=open(sys.argv[1],"rb").read(); print("    Bits per primary color channel:", {1:6,2:8,3:10,4:12}[(b[20]>>4)&7])' "\$1" ;;
esac
EOS
chmod +x "$T/bin/fake"
for t in sudo grubby dracut lsinitrd edid-decode; do ln -s fake "$T/bin/$t"; done
export PATH="$T/bin:$PATH" HOME="$T/home" SETUP_ALLOW_ROOT=1 SETUP_ASSUME_FEDORA=44 SETUP_ETC="$T/etc" \
       SETUP_SYS="$T/sys" SETUP_DEBUGFS="$T/debug" SETUP_FIRMWARE="$T/fw" SETUP_CMDLINE="$T/cmdline" SETUP_KCONFIG="$T/kconfig"
show() { sed "s#$T##g"; }
bpc_of() { python3 -c 'import sys; b=open(sys.argv[1],"rb").read(); print({1:6,2:8,3:10,4:12}[(b[20]>>4)&7], "checksum ok" if sum(b[:128])%256==0 else "BAD CHECKSUM", len(b), "bytes")' "$1"; }

echo "### status before"; bash "$E" status 2>&1 | show
echo "### try DP-2 (runtime override)"; bash "$E" try DP-2 2>&1 | show
echo "override content: $(bpc_of "$T/debug/dri/0/DP-2/edid_override")"
echo "only byte 20 and the checksum differ: $(cmp -l "$T/home/.local/state/xmg-edid/DP-2-DB70M43.orig.bin" "$T/debug/dri/0/DP-2/edid_override" | awk '{print $1}' | paste -sd, -)"
echo "### status with the override (the kernel would now show it in sysfs; fake: copy it there)"
cp "$T/debug/dri/0/DP-2/edid_override" "$NV/card0-DP-2/edid"; bash "$E" status 2>&1 | show
echo "### try again while active: still built from the kept original"; bash "$E" try DP-2 2>&1 | grep -E 'EDID says' | show
echo "### undo"; bash "$E" undo 2>&1 | show; bash "$E" undo 2>&1 | show
echo "### boot DP-2 DP-3"; bash "$E" boot DP-2 DP-3 2>&1 | show
ls "$T/fw/edid" | show; cat "$T/etc/dracut.conf.d/90-xmg-edid-8bpc.conf" | show
echo "### boot-off"; bash "$E" boot-off 2>&1 | show; ls "$T/fw/edid" | wc -l; ls "$T/etc/dracut.conf.d"
echo "### refusals"
bash "$E" try DP-1 2>&1 | tail -1 | show
bash "$E" try HDMI-A-9 2>&1 | tail -1 | show
echo "CONFIG_DRM_LOAD_EDID_FIRMWARE=n" > "$T/kconfig"; bash "$E" boot DP-2 2>&1 | tail -1 | show
python3 -c 'import sys; b=bytearray(open(sys.argv[1],"rb").read()); b[19]=3; b[127]=(-sum(b[:127]))%256; open(sys.argv[1],"wb").write(b)' "$NV/card0-DP-3/edid"
rm -f "$T"/home/.local/state/xmg-edid/DP-3-*; bash "$E" try DP-3 2>&1 | tail -1 | show
echo "### calls"; show < "$LOG"
