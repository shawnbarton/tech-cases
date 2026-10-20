#!/bin/bash
# edid-8bpc.sh and nv-heads against a fake sysfs, NVIDIA procfs and firmware directory,
# with synthetic EDID 1.4s that say 10 bpc (like the Dell S2721QS). The fakes behave like
# the real thing in the way that matters: 'detect' makes the kernel take the override
# (drm.edid_firmware runtime value), but the depth NVIDIA sends only changes at a modeset.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
E=$HERE/../testbed/setup/fedora/edid-8bpc.sh
NVH=$HERE/../testbed/bin/nv-heads
T=$(mktemp -d "${TMPDIR:-/tmp}/edid.XXXXXX")
NV=$T/sys/bus/pci/devices/0000:01:00.0/drm/card0
mkdir -p "$T/bin" "$T/etc/dracut.conf.d" "$T/fw" "$T/home" "$T/orig" "$T/proc" "$T/sys/module/drm/parameters" \
         "$NV/card0-DP-1" "$NV/card0-DP-2" "$NV/card0-DP-3"
LOG=$T/calls
: > "$T/sys/module/drm/parameters/edid_firmware"

python3 - "$NV" "$T/orig" <<'PY'
import sys
def edid(serial, bpc_code=3):
    b = bytearray(128)
    b[0:8] = bytes.fromhex("00ffffffffffff00")
    b[8:10] = bytes.fromhex("10ac")                  # DEL
    b[18], b[19] = 1, 4
    b[20] = 0x80 | (bpc_code << 4) | 0x5             # digital, DisplayPort
    def desc(tag, text):
        d = bytearray(18); d[3] = tag
        d[5:18] = (text + "\n").encode().ljust(13, b" ")[:13]
        return d
    b[72:90] = desc(0xFC, "DELL S2721QS")
    b[90:108] = desc(0xFF, serial)
    b[126] = 1
    b[127] = (-sum(b[:127])) % 256
    ext = bytearray(128); ext[0], ext[1] = 2, 3; ext[127] = (-sum(ext[:127])) % 256
    return bytes(b + ext)
nv, orig = sys.argv[1], sys.argv[2]
for conn, serial in (("DP-2", "DB70M43"), ("DP-3", "5XD0M43")):
    for path in (f"{nv}/card0-{conn}/edid", f"{orig}/{conn}.bin"):
        open(path, "wb").write(edid(serial))
    open(f"{nv}/card0-{conn}/status", "w").write("connected\n")
open(f"{nv}/card0-DP-1/edid", "wb").write(b"")
open(f"{nv}/card0-DP-1/status", "w").write("disconnected\n")
PY

# NVKMS's procfs view, generated from the EDIDs the kernel currently holds (= at a modeset).
cat > "$T/genproc.py" <<'PY'
import sys
nv, proc = sys.argv[1], sys.argv[2]
heads, dpys = ["deviceId                     : 00"], ["deviceId                     : 00"]
for head, (conn, nvname) in enumerate((("DP-3", "DP-0"), ("DP-2", "DP-1"))):
    e = open(f"{nv}/card0-{conn}/edid", "rb").read()
    depth = {2: "24bpp 4:4:4", 3: "30bpp 4:4:4"}[(e[20] >> 4) & 7]
    name = f"DELL S2721QS ({nvname})"
    heads += [f" head {head}                      : {name}", "  protocol                   : DP (A)",
              f"  mode                       : 3840 x 2160 @ 59.99{6 + head}0 Hz", f"  depth                      : {depth}"]
    dpys += [f" connector                   : {nvname}", f"  dpy                        : {name}", "   edid                      :"]
    for i in range(0, len(e), 16):
        dpys.append("   " + " ".join(f"{x:02x}" for x in e[i:i + 8]) + "  " + " ".join(f"{x:02x}" for x in e[i + 8:i + 16]))
heads += [" head 2                      : inactive", " head 3                      : inactive"]
open(f"{proc}/heads", "w").write("\n".join(heads) + "\n")
open(f"{proc}/dpys", "w").write("\n".join(dpys) + "\n")
PY
python3 "$T/genproc.py" "$NV" "$T/proc"
echo "BOOT_IMAGE=/vmlinuz root=UUID=x ro rhgb quiet" > "$T/cmdline"
echo "CONFIG_DRM_LOAD_EDID_FIRMWARE=y" > "$T/kconfig"
echo '{"outputs":[{"id":1,"name":"DP-3","enabled":true,"currentModeId":"1","modes":[{"id":"1","refreshRate":60.0,"size":{"width":3840,"height":2160}},{"id":"2","refreshRate":59.94,"size":{"width":3840,"height":2160}}]},{"id":2,"name":"DP-2","enabled":true,"currentModeId":"28","modes":[{"id":"28","refreshRate":60.0,"size":{"width":3840,"height":2160}},{"id":"29","refreshRate":59.94,"size":{"width":3840,"height":2160}},{"id":"30","refreshRate":29.97,"size":{"width":3840,"height":2160}},{"id":"35","refreshRate":60.0,"size":{"width":1920,"height":1080}}]}]}' > "$T/kscreen.json"

cat > "$T/bin/fake" <<EOS
#!/bin/bash
T="$T"; LOG="$LOG"; NV="$NV"; me=\$(basename "\$0")
case \$me in
  sudo)
    [ "\$1" = -v ] && exit 0
    [ "\$1" = -n ] && shift
    case "\$*" in
      *"echo detect >"*)               # the kernel re-reads the EDID: override if the runtime value names it
        all="\$*"; st=\${all##*> }; st=\${st//\\'/}; dir=\${st%/status}; conn=\${dir##*card0-}
        echo "detect \$conn" >> "\$LOG"
        f=\$(tr ',' '\n' < "\$T/sys/module/drm/parameters/edid_firmware" | sed -n "s|^\$conn:||p")
        if [ -n "\$f" ]; then cp "\$T/fw/\$f" "\$dir/edid"; else cp "\$T/orig/\$conn.bin" "\$dir/edid"; fi
        exit 0 ;;
    esac
    if [ "\$1" = tee ]; then
      data=\$(cat)
      case "\$2:\$data" in *edid_override:reset) : > "\$2" ;; *) printf '%s' "\$data" > "\$2" ;; esac   # debugfs: 'reset' clears
      echo "tee \$2 <- \$data" >> "\$LOG"; exit 0
    fi
    exec "\$@" ;;
  kscreen-doctor)
    if [ "\$1" = -j ]; then cat "\$T/kscreen.json"; exit 0; fi
    echo "kscreen-doctor \$*" >> "\$LOG"
    python3 - "\$T/kscreen.json" "\$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); _, out, what, *rest = sys.argv[2].split(".")
for o in d["outputs"]:
    if o["name"] == out and what == "mode" and any(str(m["id"]) == rest[0] for m in o["modes"]):
        o["currentModeId"] = rest[0]
    elif o["name"] == out and what in ("enable", "disable"):
        o["enabled"] = what == "enable"
json.dump(d, open(sys.argv[1], "w"))
PY
    python3 "\$T/genproc.py" "\$NV" "\$T/proc" ;;   # any mode change = a modeset
  grubby) echo "grubby \$*" >> "\$LOG" ;;
  dracut) echo "dracut \$*" >> "\$LOG" ;;
  lsinitrd) echo "usr/lib/modules/7.2.11-200.fc44.x86_64/kernel/drivers/gpu/drm/i915/i915.ko.xz" ;;
  edid-decode)
    [ "\$1" = --check ] && exit 0
    python3 -c 'import sys; b=open(sys.argv[1],"rb").read(); print("    Bits per primary color channel:", {1:6,2:8,3:10,4:12}[(b[20]>>4)&7])' "\$1" ;;
esac
EOS
chmod +x "$T/bin/fake"
for t in sudo kscreen-doctor grubby dracut lsinitrd edid-decode; do ln -s fake "$T/bin/$t"; done
export PATH="$T/bin:$PATH" HOME="$T/home" SETUP_ALLOW_ROOT=1 SETUP_ASSUME_FEDORA=44 SETUP_ETC="$T/etc" \
       SETUP_SYS="$T/sys" SETUP_FIRMWARE="$T/fw" SETUP_CMDLINE="$T/cmdline" SETUP_KCONFIG="$T/kconfig" \
       NV_PROCDIR="$T/proc" WAYLAND_DISPLAY=wayland-0
show() { sed "s#$T##g"; }

echo "### nv-heads"; "$NVH" | show; echo "DP-2 depth: $("$NVH" --depth DP-2)"; "$NVH" --depth HDMI-A-1; echo "unknown connector rc=$?"
echo "### status before"; bash "$E" status 2>&1 | show
echo "### try DP-2"; bash "$E" try DP-2 2>&1 | show
echo "only byte 20 and the checksum differ: $(cmp -l "$T/orig/DP-2.bin" "$NV/card0-DP-2/edid" | awk '{print $1}' | paste -sd, -)"
echo "### status during"; bash "$E" status 2>&1 | show
echo "### undo"; bash "$E" undo 2>&1 | show
echo "runtime value now: '$(cat "$T/sys/module/drm/parameters/edid_firmware")'"; bash "$E" undo 2>&1 | show
echo "### try DP-2 DP-3, then undo both"; bash "$E" try DP-2 DP-3 2>&1 | grep -E 'Override|now gets' | show; bash "$E" undo 2>&1 | grep 'now gets' | show
echo "### try DP-2, then try DP-3: both stay set; undo restores both"
bash "$E" try DP-2 2>&1 | grep -E 'Override|now gets' | show; bash "$E" try DP-3 2>&1 | grep -E 'Override|now gets' | show
bash "$E" undo 2>&1 | grep -E 'now gets' | show; "$NVH" | grep -o '^DP-[0-9]\|[0-9]*bpp' | paste -sd' '
echo "### an interrupted undo (value already cleared, DP-2 still at 8 bpc) can be run again"
bash "$E" try DP-2 >/dev/null 2>&1; printf , > "$T/sys/module/drm/parameters/edid_firmware"; bash "$E" undo 2>&1 | grep -E 'now gets|nothing' | show
echo "### a monitor disabled in Display settings is skipped, not switched back on"
python3 - "$T/kscreen.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["outputs"][0]["enabled"] = False; json.dump(d, open(sys.argv[1], "w"))
PY
bash "$E" try DP-3 2>&1 | grep -E 'DP-3' | grep -v 'copy:' | show; grep -c 'output.DP-3.enable' "$LOG"
python3 - "$T/kscreen.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["outputs"][0]["enabled"] = True; d["outputs"][0]["modes"] = d["outputs"][0]["modes"][:1]; json.dump(d, open(sys.argv[1], "w"))
PY
echo "### no other mode of the same size -> skipped with a note"
bash "$E" undo 2>&1 | grep -E 'DP-3' | show
echo "### a debugfs override left by the old version is reported and cleared"
mkdir -p "$T/debug/dri/0/DP-2" "$T/debug/dri/0/DP-3"; echo "nvidia-drm dev=0000:01:00.0 unique=0000:01:00.0" > "$T/debug/dri/0/name"
: > "$T/debug/dri/0/DP-3/edid_override"; cp "$T/fw/edid/xmg-8bpc-DP-2-DB70M43.bin" "$T/debug/dri/0/DP-2/edid_override"
SETUP_DEBUGFS="$T/debug" bash "$E" status 2>&1 | grep debugfs | show
SETUP_DEBUGFS="$T/debug" bash "$E" undo 2>&1 | grep -E 'now gets' | show; echo "debugfs DP-2 override now: $(wc -c < "$T/debug/dri/0/DP-2/edid_override") bytes"
echo "### boot DP-2 DP-3 (nvidia not in the initramfs: no dracut)"; bash "$E" boot DP-2 DP-3 2>&1 | show; ls "$T/etc/dracut.conf.d" | wc -l
echo "### boot-off"; bash "$E" boot-off 2>&1 | show; ls "$T/fw/edid" | wc -l
echo "### refusals"
WAYLAND_DISPLAY= bash "$E" try DP-2 2>&1 | tail -1 | show
bash "$E" try DP-1 2>&1 | tail -1 | show
bash "$E" try HDMI-A-9 2>&1 | tail -1 | show
echo "CONFIG_DRM_LOAD_EDID_FIRMWARE=n" > "$T/kconfig"; bash "$E" boot DP-2 2>&1 | tail -1 | show
python3 -c 'import sys; b=bytearray(open(sys.argv[1],"rb").read()); b[19]=3; b[127]=(-sum(b[:127]))%256; open(sys.argv[1],"wb").write(b)' "$NV/card0-DP-3/edid"
rm -f "$T"/home/.local/state/xmg-edid/DP-3-*; bash "$E" try DP-3 2>&1 | tail -1 | show
echo "### calls"; show < "$LOG"
