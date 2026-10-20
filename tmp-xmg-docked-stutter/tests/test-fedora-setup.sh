#!/bin/bash
# Test the Fedora setup scripts against fake dnf/rpm/akmods/modinfo/mokutil/systemctl.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SETUP=$HERE/../testbed/setup
T=$(mktemp -d "${TMPDIR:-/tmp}/fed.XXXXXX")
mkdir -p "$T/bin" "$T/etc/rpm" "$T/etc/modprobe.d" "$T/etc/pki/akmods/certs" "$T/mods" \
         "$T/modules/7.2.10-200.fc44.x86_64/build" "$T/modules/7.2.11-200.fc44.x86_64/build"
LOG=$T/calls
cat > "$T/bin/fake" <<EOS
#!/bin/bash
# One fake for every tool; behaviour by name.
T="$T"; LOG="$LOG"; me=\$(basename "\$0")
case \$me in
  sudo) [ "\$1" = -n ] && shift; exec "\$@" ;;
  uname) echo 7.2.10-200.fc44.x86_64 ;;
  rpm) case \$1 in
         -q) shift; rc=0; for p in "\$@"; do grep -qx "\$p" "\$T/installed" 2>/dev/null || rc=1; done; exit \$rc ;;
         -qa) cat "\$T/installed" 2>/dev/null ;;
       esac ;;
  dnf) echo "dnf \$*" >> "\$LOG"
       [ -e "\$T/dnf-fail" ] && exit 1
       touch "\$T/installed"
       case \$1 in
         install) for a in "\$@"; do case \$a in -*|install) ;; *) grep -qx "\$a" "\$T/installed" || echo "\$a" >> "\$T/installed" ;; esac; done ;;
         do) mode=
             for a in "\$@"; do
               case \$a in
                 --action=remove) mode=rm ;;
                 --action=install) mode=add ;;
                 -*|do) ;;
                 *) if [ "\$mode" = rm ]; then
                      grep -v -x -e "\$(printf '%s' "\$a" | sed 's/\*/.*/g; s/\[0-9\]/[0-9]/g; s/\[a-z\]/[a-z]/g')" "\$T/installed" > "\$T/installed.new" || true
                      mv "\$T/installed.new" "\$T/installed"
                    elif [ "\$mode" = add ]; then
                      grep -qx "\$a" "\$T/installed" || echo "\$a" >> "\$T/installed"
                    fi ;;
               esac
             done ;;
       esac ;;
  akmods) echo "akmods \$*" >> "\$LOG"
       k=\${!#}; name=nvidia; prev=
       for a in "\$@"; do [ "\$prev" = --akmod ] && name=\$a; prev=\$a; done
       lic="Dual MIT/GPL"; grep -q without_kmod_nvidia_detect "\$T/etc/rpm/macros.nvidia-kmod" 2>/dev/null && lic=NVIDIA
       [ -e "\$T/ignore-macro" ] && lic="Dual MIT/GPL"
       ver=615.78.08; [ "\$name" = nvidia-580xx ] && ver=580.178.04
       printf '%s\n%s\n' "\$ver" "\$lic" > "\$T/mods/\$k"
       mkdir -p "\$T/modules/\$k/extra/\$name" ;;
  modinfo) if [ "\$1" = -k ]; then k=\$2; shift 2; else k=7.2.10-200.fc44.x86_64; fi
       case \$2 in
         version) sed -n 1p "\$T/mods/\$k" 2>/dev/null ;;
         license) sed -n 2p "\$T/mods/\$k" 2>/dev/null ;;
         parm) echo "modeset:Enable modesetting (bool)"; echo "vblank:Use vblank events (bool)" ;;
       esac ;;
  mokutil) case \$1 in
         --sb-state) cat "\$T/sb" 2>/dev/null || echo "SecureBoot disabled" ;;
         --test-key) [ -e "\$T/enrolled" ] && echo "\$2 is already enrolled" || echo "\$2 is not enrolled" ;;
       esac ;;
  systemctl) echo "systemctl \$*" >> "\$LOG"
       case \$1 in show) echo plasmalogin.service ;; is-enabled) cat "\$T/powerd" 2>/dev/null || echo enabled ;; is-active) echo active ;; cat) exit 0 ;; esac ;;
  *) echo "\$me \$*" >> "\$LOG" ;;
esac
exit 0
EOS
chmod +x "$T/bin/fake"
for t in sudo uname rpm dnf akmods modinfo mokutil systemctl dracut boltctl kscreen-doctor powerprofilesctl; do ln -s fake "$T/bin/$t"; done
export PATH="$T/bin:$PATH" SETUP_ASSUME_FEDORA=44 SETUP_ETC="$T/etc" SETUP_MODULES="$T/modules" SETUP_ALLOW_ROOT=1
F=$SETUP/fedora
show() { sed "s#$T##g"; }
step() { : > "$LOG"; echo "################ $*"; }
calls() { echo "-- calls:"; show < "$LOG"; }
files() { echo "-- macro: $(cat "$T/etc/rpm/macros.nvidia-kmod" 2>/dev/null || echo none) | gsp: $(cat "$T/etc/modprobe.d/zz-nvidia-gsp.conf" 2>/dev/null || echo none)"; }

step "01-base.sh (dry run)"; DRYRUN=1 bash "$F/01-base.sh" 2>&1 | grep -E 'dry-run|==>' | show
step "02-nvidia.sh 615-open"; bash "$F/02-nvidia.sh" 615-open 2>&1 | grep -E '==>|nvidia [0-9]|error' | show; echo "exit ${PIPESTATUS[0]}"; files; calls
step "02-nvidia.sh 615-closed-gsp-off"; bash "$F/02-nvidia.sh" 615-closed-gsp-off 2>&1 | grep -E 'nvidia [0-9]|error|N/A' | show; echo "exit ${PIPESTATUS[0]}"; files
step "02-nvidia.sh 580-open (branch switch to the default)"; bash "$F/02-nvidia.sh" 580-open 2>&1 | grep -E 'nvidia [0-9]|error' | show; echo "exit ${PIPESTATUS[0]}"; files; grep '^dnf' "$LOG" | show
step "02-nvidia.sh 615-open again (back from 580)"; bash "$F/02-nvidia.sh" 615-open 2>&1 | grep -E 'nvidia [0-9]|error' | show; files
step "akmods ignores the macro -> must fail"; touch "$T/ignore-macro"; bash "$F/02-nvidia.sh" 615-closed 2>&1 | grep -E 'error|nvidia [0-9]' | show; echo "exit ${PIPESTATUS[0]}"; rm -f "$T/ignore-macro"
step "Secure Boot on, key not enrolled -> stop before building"; echo "SecureBoot enabled" > "$T/sb"; bash "$F/02-nvidia.sh" 615-open 2>&1 | grep -E 'Secure Boot is on|kmodgenca' | show; echo "exit ${PIPESTATUS[0]}"; grep -c '^akmods' "$LOG" | sed 's/^/akmods calls: /'
step "Secure Boot on, key enrolled -> builds"; touch "$T/enrolled" "$T/etc/pki/akmods/certs/public_key.der"; bash "$F/02-nvidia.sh" 615-open 2>&1 | grep -E 'nvidia [0-9]|error' | show; echo "exit ${PIPESTATUS[0]}"; rm -f "$T/sb" "$T/enrolled"
step "02-nvidia.sh status"; bash "$F/02-nvidia.sh" status 2>&1 | show | head -12
step "02-nvidia.sh bogus"; bash "$F/02-nvidia.sh" bogus >/dev/null 2>&1; echo "exit $?"
step "knobs.sh vblank on / status / off, powerd off"; bash "$F/knobs.sh" vblank on 2>&1 | show; bash "$F/knobs.sh" status 2>&1 | show; bash "$F/knobs.sh" vblank off | show; bash "$F/knobs.sh" powerd off; calls
step "03-sessions.sh (dry run)"; DRYRUN=1 bash "$F/03-sessions.sh" 2>&1 | grep -E 'dry-run|login manager' | show
step "install-testbed.sh (dry run, not in a Plasma session)"; HOME=$T/home DRYRUN=1 bash "$SETUP/install-testbed.sh" 2>&1 | grep -E 'dry-run|==>|run inside|no external' | show

step "freeze on, then a driver switch unlocks/relocks NVIDIA, then freeze off"
bash "$F/freeze.sh" on | show; bash "$F/02-nvidia.sh" 615-closed 2>&1 | grep -E 'nvidia [0-9]|error' | show
grep -E '^dnf versionlock' "$LOG" | show; bash "$F/freeze.sh" off | show
step "failed package transaction restores the previous settings"
bash "$F/02-nvidia.sh" 615-open >/dev/null 2>&1; files; touch "$T/dnf-fail"
bash "$F/02-nvidia.sh" 580-closed-gsp-off 2>&1 | grep -E 'error' | show; echo "exit ${PIPESTATUS[0]}"; files; rm -f "$T/dnf-fail"
step "branch switch keeps Dynamic Boost disabled if it was disabled"
echo disabled > "$T/powerd"; bash "$F/02-nvidia.sh" 580-open >/dev/null 2>&1; grep -E '^systemctl (enable|disable)' "$LOG" | show; rm -f "$T/powerd"
step "--rebuild only when the kmod already exists (it does now)"
bash "$F/02-nvidia.sh" 615-closed >/dev/null 2>&1; grep '^akmods' "$LOG" | show
