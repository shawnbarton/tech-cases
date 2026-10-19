# Test bed: Fedora KDE 44 on the XMG Fusion 15 (E24)

*2026-10-19. A fresh install used only to find what removes the docked stutter. Scripts live in `testbed/`; every one supports `DRYRUN=1` to preview its commands first.*

## 1. Why Fedora KDE Plasma 44

| Need | Fedora KDE 44 |
|---|---|
| KWin ≥ 6.7.3 (triple buffering on NVIDIA; switchable off for A/B) | KWin 6.7.5 |
| Same NVIDIA driver as **open or proprietary** module (GSP on/off A/B without changing version) | RPM Fusion akmods: one macro switches the module type of 615.78.08; a 580xx branch is available too |
| Xwayland ≥ 24.1 (explicit sync for X11 apps on NVIDIA) | 24.1.x |
| GNOME and COSMIC sessions for cross-checks | official repos |
| Full Intel media driver (AV1 on Raptor Lake) | RPM Fusion `intel-media-driver` |

Why not the alternatives:
- **Plasma 6.8:** not yet. 6.8.0 has an open regression, KDE 527251: flicker on DP/USB-C outputs with Intel plus NVIDIA, which is exactly this laptop. Fedora gets 6.8 a little after Fedora 45 ships (late October); stay on 6.7.5 for the main campaign.
- **CachyOS / Arch:** they ship Plasma 6.8.0 and the open modules only, and CachyOS changes scheduler and NVIDIA defaults, which muddies results.
- **Kubuntu 26.10:** has driver 595 as both module types, but will never get Plasma 6.8 and has no COSMIC.
- **TUXEDO tools:** `tuxedo-drivers` and Control Center refuse to load on XMG Raptor Lake hardware. Leave fans and keyboard to the firmware.

Your `edid_setup` 8 bpc installer targets initramfs-tools with GRUB or kernelstub, not Fedora's dracut and grubby. Leave it off for these tests: one variable at a time, and the dock-port corruption is a separate issue.

## 2. Before installing

- **BIOS:**
  - Graphics mode **Hybrid** for the main runs; dGPU-only comes later in Phase C.
  - **Secure Boot off** is simplest for a test bed, because switching driver module types rebuilds them. If you keep it on, `02-nvidia.sh` walks you through the one-time key enrollment.
- **Get this folder onto the laptop:** clone `shawnbarton/tech-cases`, branch `claude/cosmic-comp-1915-fix-keo2dc`, once the push from this session works. Otherwise use the patch or archive sent in chat. In the repo or archive, the scripts are under `tmp-xmg-docked-stutter/`.

## 3. Install and set up

1. Install **Fedora KDE Plasma Desktop 44** with the default (btrfs) layout. Create your user and connect to the network. Undocked is fine for this part.
2. Base system, RPM Fusion, tools, and the Alt+SysRq emergency keys:
   ```
   cd tmp-xmg-docked-stutter/testbed/setup/fedora
   ./01-base.sh
   reboot
   ```
3. NVIDIA driver (current branch, open modules):
   ```
   ./02-nvidia.sh open
   reboot
   ./02-nvidia.sh status        # expect 615.78.08 (open), GSP firmware version shown
   ```
4. **Dock** (if the dock asks for authorization: `boltctl list`, then `boltctl enroll --policy auto <uuid>`). Turn both Dells on. Close the lid, or disable the built-in display while docked with the lid open. Then, inside the Plasma session:
   ```
   ../install-testbed.sh        # tools into ~/.local/bin, KWin login script, frame log on,
                                # Adaptive Sync Never on the Dells, power profile fixed
   ```
5. Log out and back in (docked), then `stuttertest info`. Check:
   - the KWin version (6.7.x) and the render GPU (Intel in hybrid mode);
   - "KWIN_LOG_PERFORMANCE_DATA=1" under the running KWin;
   - no GPU pollers listed.

Optional, any time: `./03-sessions.sh` adds COSMIC and GNOME sessions and keeps KDE's login screen.

## 4. How a test works

- `stuttertest run NAME [--clock …] [--duration 90]` measures one test while you use the desktop, then shows late frames per monitor and asks how smooth it felt (1–5).
- `stuttertest report` compares all runs. The results are in `~/stuttertest/`.
- **Use the same routine every time** (90 s):
  1. 20 s: cursor circles over the empty desktop.
  2. 20 s: drag a window across both Dells.
  3. 20 s: scroll a long web page.
  4. 30 s: a 4K YouTube video, windowed.
- Settings that need a new login: `stuttertest kwin set …`, then log out and back in. The KWin settings are:
  - `tb=default|on|off` (triple buffering)
  - `gpu=default|nvidia` (who composites)
  - `margin=<µs>|default` (safety margin)
- Clock settings apply only during a run and are reset afterwards:
  - `mem[=MHz]`: memory clock lock
  - `gr[=MHz]`: graphics clock floor
  - `pm-max`, `pm-consistent`: PowerMizer modes
  - `p0`: a tiny load that holds the GPU at full power, NVIDIA's own diagnostic

  Combine them with commas.
- **Rules:**
  - On AC power and docked.
  - No suspend, VT switch or dock re-plug in the middle of a session: KWin restarts its frame log.
  - GPU pollers closed: system-monitor GPU widgets, nvtop, mangohud.
  - `--smi` logs P-states, but adds GPU polling. Use it for a second run of an interesting test, not for the main one.

## 5. Test campaign

Run phases in order. Two runs per test cut down noise (`a1-default`, `a1-default-2`).

**Phase A: hybrid mode, Intel composites, driver 615 open (the default setup)**
```
stuttertest run a1-default --duration 90                 # KWin 6.7.5: triple buffering on
stuttertest kwin set tb=off        # log out/in
stuttertest run a2-tb-off --duration 90
stuttertest kwin set tb=default    # log out/in
stuttertest run a3-mem --clock mem --duration 90
stuttertest run a3-gr --clock gr --duration 90
stuttertest run a3-pm-max --clock pm-max --duration 90
stuttertest run a3-pm-consistent --clock pm-consistent --duration 90
stuttertest run a3-p0 --clock p0 --duration 90
stuttertest kwin set margin=3000   # log out/in
stuttertest run a4-margin3000 --duration 90
stuttertest kwin set margin=default
```

**Phase B: hybrid mode, NVIDIA composites** (`stuttertest kwin set gpu=nvidia`, lid closed, log out/in; `stuttertest info` must show an NVIDIA render GPU)
```
stuttertest run b1-default --duration 90
stuttertest run b3-p0 --clock p0 --duration 90
stuttertest run b3-mem --clock mem --duration 90
```
Then go back with `stuttertest kwin set gpu=default`. If X11 apps flicker in this mode, note it; it doesn't affect the frame numbers.

**Phase C: BIOS dGPU-only.** Repeat `c1-default`, `c2-tb-off` and `c3-p0` (the render GPU is NVIDIA automatically).

**Phase D: GSP off (same driver, proprietary modules).** Repeat the best and worst tests from Phases A–C, then switch back with `./02-nvidia.sh open`:
```
./02-nvidia.sh closed-gsp-off && reboot
./02-nvidia.sh status       # GSP Firmware Version: N/A
```

**Phase E: NVIDIA vblank timestamps** (`./knobs.sh vblank on`, reboot). Repeat `a1`/`b1`, then `./knobs.sh vblank off`.

**Phase F: Dynamic Boost off** (`./knobs.sh powerd off`). Repeat `a1`, then `./knobs.sh powerd on`. Otherwise keep it in the same state for every run.

**Phase G: older driver branch** (`./02-nvidia.sh legacy-open`, reboot). Repeat `a1`, `a3-p0` and `b1`. Use this immediately instead if 615 hangs after a monitor power-cycles (see §6).

**Phase H, optional: other desktops.** Run the same routine in GNOME and COSMIC sessions with `stuttertest run h-gnome --smi` (no KWin frame log there: judge by feel plus P-states).

**How to read the results:**
- **`tb=off` clearly worse than default:** triple buffering matters. Plasma ≥ 6.7.3 is the fix, and your old TUXEDO install (6.6.x) lacked it.
- **`p0` fixes it, locks don't:** it's NVIDIA's low-power latency (NV 4830125). That is evidence for [open-gpu-kernel-modules #650](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/650), and the workaround is a held clock or load while docked.
- **A lock or PowerMizer mode fixes it:** make it automatic with `testbed/clockfloor/install.sh`, which applies only while docked on AC.
- **GSP off fixes it:** a firmware-path issue. Report it to NVIDIA with that A/B.
- **NVIDIA compositing (B) beats Intel (A) in hybrid mode:** keep `gpu=nvidia` for docked use.

## 6. Known risks and recovery

- **Driver 615 and dock power-cycles:** after a DisplayPort monitor power-cycles behind a dock or hub, KWin can hang waiting on the GPU firmware ([#1392](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1392); one report is an RTX 4070 laptop in hybrid mode). Avoid turning the Dells off and on during a session. If it hits:
  1. Press Alt+SysRq + S, U, B, a few seconds apart. `01-base.sh` enables exactly these three; holding the power button also works.
  2. Then consider Phase G's 580 branch for the rest of the campaign.
- **A login breaks after a `stuttertest kwin set` change:** unplug the dock and log in (the login script does nothing undocked), then `stuttertest kwin set gpu=default tb=default margin=default`.
- **A driver switch fails to build:** `./02-nvidia.sh status`, `journalctl -u akmods`, `/var/cache/akmods/nvidia/*.log`. `./02-nvidia.sh open` returns to the default.
- **Microcode:** `stuttertest info` prints it. The newest for this CPU (06-b7-01) is 0x137. Update the XMG BIOS if it's lower.

## 7. What to send back

- `stuttertest report`
- the `~/stuttertest/info-*.txt` files, or simply `tar czf stuttertest.tgz ~/stuttertest`
- anything odd you noticed during the runs (flicker, hangs, X11 app problems)
