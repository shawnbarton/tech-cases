# Test bed: Fedora KDE 44 on the XMG Fusion 15 (E24)

*2026-10-19. A fresh install used only to find what removes the docked stutter. Scripts live in `testbed/`. The setup scripts (`setup/fedora/*.sh`, `setup/install-testbed.sh`) support `DRYRUN=1` to preview their commands.*

## 1. Why Fedora KDE Plasma 44

| Need | Fedora KDE 44 |
|---|---|
| KWin ≥ 6.7.3 (triple buffering on NVIDIA; switchable off for A/B) | KWin 6.7.5 |
| Same NVIDIA driver as **open or proprietary** module (GSP on/off A/B without changing version) | RPM Fusion akmods: one macro switches the module type, for both 580.178.04 and 615.78.08 |
| Xwayland ≥ 24.1 (explicit sync for X11 apps on NVIDIA) | 24.1.x |
| GNOME and COSMIC sessions for cross-checks | official repos |
| Full Intel media driver (AV1 on Raptor Lake) | RPM Fusion `intel-media-driver` |

**Driver: 580.178.04 (NVIDIA's long-term branch) is the default, 615 is a comparison.**
- **615:** it has open regressions that would confound the test. Screens blink as the memory clock switches power states ([#1391](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1391)), and KWin can hang after a DisplayPort monitor power-cycles behind a dock ([#1392](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1392)).
- **595:** there's an open report of lag on monitors wired to the NVIDIA GPU of KDE laptops, including an RTX 4070 laptop. Users say it started with 595.58.03 and 590.48.01 was fine ([#1090](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1090)). Your old install ran 595.71.05. RPM Fusion no longer packages 595 for Fedora 44 anyway.
- **580:** it predates all of these and is supported until 2028. It isn't known to be clean: your #1915 comment lists stutter on 580.173.02, but that was on COSMIC / KWin 6.6 without triple buffering. It is simply the branch with the fewest known confounders.

Why not the alternatives:
- **Plasma 6.8:** not yet. 6.8.0 has an open regression, KDE 527251: flicker on DP/USB-C outputs with Intel plus NVIDIA, which is exactly this laptop. Fedora gets 6.8 shortly after Fedora 45 ships (late October), so freeze the stack for the campaign (§3, step 6).
- **CachyOS / Arch:** they ship Plasma 6.8.0 and the open modules only, and CachyOS changes scheduler and NVIDIA defaults, which muddies results.
- **Kubuntu 26.10:** has driver 595 as both module types, but will never get Plasma 6.8 and has no COSMIC.
- **TUXEDO tools:** `tuxedo-drivers` and Control Center refuse to load on XMG Raptor Lake hardware. Leave fans and keyboard to the firmware.

Your `edid_setup` 8 bpc installer targets initramfs-tools with GRUB or kernelstub, not Fedora's dracut and grubby. Leave it off for these tests: one variable at a time, and the dock-port corruption is a separate issue.

## 2. Before installing

- **BIOS:**
  - Graphics mode **Hybrid** for the main runs; dGPU-only comes later in Phase C.
  - **Secure Boot off** is simplest for a test bed, because switching driver module types rebuilds them. If you keep it on, `02-nvidia.sh` walks you through the one-time key enrollment.
- **Get this folder onto the laptop:** `git clone -b claude/cosmic-comp-1915-fix-keo2dc https://github.com/shawnbarton/tech-cases`. Everything is under `tech-cases/tmp-xmg-docked-stutter/`.

## 3. Install and set up

1. Install **Fedora KDE Plasma Desktop 44** with the default (btrfs) layout. Create your user and connect to the network. Undocked is fine for this part.
2. Base system, RPM Fusion, tools, and the Alt+SysRq emergency keys:
   ```
   cd tech-cases/tmp-xmg-docked-stutter/testbed/setup/fedora
   ./01-base.sh
   reboot
   ```
3. NVIDIA driver (580 long-term branch, open modules):
   ```
   ./02-nvidia.sh 580-open
   reboot
   ./02-nvidia.sh status        # expect 580.178.04 (open), GSP firmware version shown
   ```
4. **Dock.** If the dock asks for authorization: `boltctl list`, then `boltctl enroll --policy auto <uuid>`. Turn both Dells on. **Pick one lid state for the whole campaign:** lid closed, or lid open with the built-in display disabled in Display settings. Then, inside the Plasma session:
   ```
   ../install-testbed.sh        # tools into ~/.local/bin, KWin login script with frame log,
                                # Adaptive Sync Never on the Dells, fixed power profile,
                                # no automatic screen-off / sleep / lock on AC
   stuttertest kwin set lidcheck=off      # only if you work lid-open with the built-in display disabled
   ```
5. Log out and back in (docked), then `stuttertest info`. Check:
   - the KWin version (6.7.x) and the render GPU (Intel in hybrid mode);
   - `KWIN_LOG_PERFORMANCE_DATA=1` under the running KWin, and "frame logs open" lists one file per Dell;
   - no GPU pollers listed.
6. **Freeze the stack** so no update changes KWin, the kernel, Mesa or the driver mid-campaign:
   ```
   ./freeze.sh on               # ./freeze.sh off when the campaign is over
   ```
   Don't apply Discover updates during the campaign. Driver changes only go through `02-nvidia.sh`, which handles the lock itself.

Optional, any time: `./03-sessions.sh` adds COSMIC and GNOME sessions and keeps KDE's login screen.

## 4. How a test works

- `stuttertest run NAME [--clock …] --duration 90` measures one test while you use the desktop. It then shows, per monitor, the late frames, missed refreshes and the share of frames KWin triple-buffered. It asks whether you saw stutter and whether you saw static/corruption (yes/no), plus an optional one-line note. The terminal beeps when the time is up.
- The late-frame count is the measurement. It also says *how much* stutter there was when the answer is yes. Your yes/no is the cross-check that the numbers match what you see. Corruption is the separate dock-port bug, recorded per run for free in case it follows a driver or setting.
- After the per-monitor summary a run prints **details**: how many late frames were ready in time (so the delay came after rendering), whether they come in bursts, and how often both Dells were late at the same moment compared with chance. `stuttertest analyze [RUN]` shows the same for any earlier run.
- **Mark static and blanking while it happens, with a keyboard shortcut.**
  - `install-testbed.sh` adds a menu entry "Stuttertest: mark static". Bind it once under System Settings → Keyboard → Shortcuts → Add New → Application. Pick a key your free hand finds without looking (e.g. Meta+Z).
  - KWin runs global shortcuts even while you're dragging a window. Any other key goes to the drag, and Enter ends it.
  - Without a shortcut: let go of the window, then press Enter in the `stuttertest` terminal (type `m` and Enter in a run without `--duration`). A second or two late is fine.
  - Afterwards the details list each mark, with what happened in the 1.5 s before it: late frames, gaps between flips, P-state changes (with `--smi`), and kernel or KWin log lines.
- Each run records by itself which X11 apps were open, and saves the kernel and KWin log for its time window (`kernel.log`, `kwin.log` in the run folder). You don't need to know which apps are X11.
- `stuttertest report` compares all runs. The results are in `~/stuttertest/`.
- **The routine** is normal use of the applications where you see the stutter, on the Dells. Phase 0 (§5) pins down which ones. Once chosen, keep it the same for every run (90 s):
  1. 30 s: the app that showed it most: scroll, switch views, type.
  2. 30 s: a second app that showed it.
  3. 20 s: cursor over the empty desktop. On COSMIC that was where it showed.
  4. 10 s: drag a window from one Dell to the other.
- **Settings that need a new login** (`stuttertest kwin set …`, then log out and back in):
  - `tb=default|on|off`: triple buffering
  - `gpu=default|nvidia`: who composites
  - `margin=<µs>|default`: the safety margin before each refresh
  - `lidcheck=on|off` and `perf=on|off`
- **Clock settings apply only during the run** and are reset afterwards:
  - `mem[=MHz]`: memory clock lock (default: the highest supported)
  - `gr[=MHz]`: graphics clock floor (default 900)
  - `pm-max`, `pm-consistent`: PowerMizer modes
  - `p0`: a small uncapped load on the NVIDIA GPU, which holds it at full power (NVIDIA's own diagnostic)
  - `p0ctl`: the same load on the Intel GPU, as a control

  Combine them with commas. The values applied are recorded with the run.
- **Rules:**
  - On AC power and docked. No suspend, VT switch, dock re-plug or monitor power-off in the middle of a session: KWin restarts its frame log (and on driver 615, in Phase E, a monitor power-cycle can hang KWin; §6).
  - GPU pollers closed: system-monitor GPU widgets, nvtop, mangohud.
  - **Compare clock tests with a baseline from the same login** (a run without `--clock` just before them). Settings that need a new login are compared across logins by nature, so keep everything else identical.
  - `--smi` logs P-states, but adds GPU polling. Use it on a second run of an interesting test.
  - Names start with the phase letter; repeats get a suffix (`a1`, `a1-2`, `f-a1-powerd-off`).

## 5. Test campaign

**Phase 0: find the triggers** (default setup, one login). Use one app per 60 s run. Use it normally on the Dells (scroll, type, switch views), and drag its window from one Dell to the other a few times. Mark every static or blanking moment (§4).
```
stuttertest run 0-konsole --duration 60      # e.g. run `ls -lR /usr` so output scrolls
stuttertest run 0-dolphin --duration 60
stuttertest run 0-firefox --duration 60      # scroll a long page
stuttertest run 0-sysset --duration 60       # System Settings
stuttertest run 0-desktop --duration 60      # no app: cursor over the empty desktop, panel, menus
stuttertest run 0-x11app --duration 60       # only if you use one: Discord, Steam, a game
```
Whichever runs show the stutter (your yes/no answer plus late frames) define the routine for the rest of the campaign. In the note, say what exactly stuttered: the cursor, window contents (scrolling, typing), or window movement. That answers your record's open question "cursor only, or window contents too?".

Why these apps:
- Konsole, Dolphin, Firefox and System Settings are all native Wayland on Fedora.
- Konsole and Dolphin are Qt Widgets apps, which most likely draw with the CPU into shared-memory buffers.
- Firefox and System Settings (Qt Quick) draw with the GPU.
- Your first runs showed static and blanking when Konsole or Dolphin was dragged onto DP-2, and not right away with Firefox. That makes this split worth a closer look (Phase S).

One more Phase 0 check, for the other open question ("internal panel too, or only the externals?"). Temporarily enable the built-in display (it's driven by the Intel GPU) and log out and in. Then repeat whichever run stuttered, using the apps **only on the built-in display**:
```
stuttertest run 0-internal --duration 60
```
Then go back to your chosen lid/display state and log out and in. The built-in display has no NVIDIA involvement, so if it stays smooth while the Dells stutter, the problem sits in the NVIDIA output path.

**Phase S: the static trigger** (default setup, same login, 30 s each). Drag the named window onto the named Dell and back, about every 5 s, and mark each static or blanking moment:
```
stuttertest run s-konsole-dp2 --duration 30                # baseline: does it reproduce?
stuttertest run s-konsole-dp3 --duration 30                # Konsole onto DP-3 only: the other dock port
stuttertest run s-sysset-dp2 --duration 30                 # System Settings (GPU-drawn) onto DP-2
stuttertest run s-konsole-mem --clock mem --duration 30    # Konsole onto DP-2, memory clock held at max
stuttertest run s-konsole-p0 --clock p0 --duration 30      # Konsole onto DP-2, NVIDIA GPU held at full power
stuttertest run s-konsole-p0ctl --clock p0ctl --duration 30
stuttertest run s-konsole-smi --smi --duration 30          # Konsole onto DP-2, logging P-state changes
```
Two extra checks while the static is visible:
- **A phone photo or short video.** The pattern says where it comes from:
  - fine snow or sparkles: the signal on the link;
  - horizontal bands or repeated lines: the display engine fetching the picture from memory too late;
  - blocks or tiles: the picture's contents.
- **A screenshot** (Print, Spectacle). KWin draws screenshots itself. Static that shows up in the screenshot is in the picture KWin composed. Static that doesn't happens after that: in the copy, the scanout or the link.

**Test patterns: which content brings it up.** Your static stays as long as the same content is on DP-2 and changes when the content does. So a fixed pattern held on DP-2 is a cleaner trigger than a moving window. There are two versions of the same patterns, one drawn by Firefox (GPU) and one by Konsole (CPU):
```
firefox testbed/patterns/static-patterns.html   # move it to DP-2, press F for full screen
```
Step with the arrow keys and press S (static) or C (clean) on each pattern, and R for the list. A makes the pattern move by a pixel per frame. Then put Konsole full screen on DP-2 (Ctrl+Shift+F) and run `testbed/patterns/term-patterns.sh`: same idea, s or c and Enter at each pattern. Take a photo of the list at the end of each.

**The 8 bpc test: the strongest hypothesis in your record, and it works with NVIDIA after all.**
- NVIDIA's driver takes an override EDID from the kernel, and it caps a DP link's colour depth at what the EDID says (`nvidia-drm-connector.c` passes it on as `overrideEdid`; `nvkms-dpy.c` sets the DP maximum from the EDID's bits per colour).
- Your Dells say 10. Windows runs them at 8.
- `edid-8bpc.sh` changes only that field, checks the result with `edid-decode`, and keeps the original. Do this on driver 580 only: on 615, a monitor power-cycle behind the dock can hang KWin (#1392).
```
cd testbed/setup/fedora
./edid-8bpc.sh status        # DP-2 and DP-3: EDID bpc 10
./edid-8bpc.sh try DP-2      # then switch the DP-2 Dell off with its button, wait 5 s, on again
./edid-8bpc.sh status        # DP-2: EDID bpc 8, runtime override yes
stuttertest run s-8bpc-konsole-dp2 --duration 30      # plus the patterns that showed static
./edid-8bpc.sh undo          # power-cycle the Dell again
stuttertest run s-10bpc-konsole-dp2 --duration 30     # does it come back?
```
`try` lasts until reboot. If 8 bpc cures it, `./edid-8bpc.sh boot DP-2 DP-3` makes it permanent: firmware file, `drm.edid_firmware` kernel argument, and the initramfs if nvidia-drm loads there. Reboot afterwards. `./edid-8bpc.sh boot-off` undoes it.

How to read Phase S:
- **Static gone at 8 bpc and back at 10:** the 10 bpc link through that dock port. Keep 8 bpc (`boot`). At most, smooth gradients band slightly more; Windows runs these monitors at 8 bpc too.
- **The same patterns show static in Firefox and in Konsole:** it's the content on the way to the monitor, not the app.
- **Only Konsole's patterns show it:** how the app's picture reaches KWin matters.
- **DP-3 stays clean while DP-2 shows static:** the port again, as in your record (the static followed the dock port when the cables were swapped).
- **System Settings stays clean while Konsole shows static:** the way the app's picture reaches KWin matters. A pure link problem wouldn't care.
- **`mem` or `p0` stops it while `p0ctl` doesn't:** the NVIDIA GPU's power-state changes, the same family as the stutter. The clockfloor service is then a workaround for both.
- **The marks line up with P-state changes (`s-konsole-smi`) or with bursts of late frames:** same conclusion, measured instead of seen.

**Phase A: hybrid mode, Intel composites, driver 580 open (the default setup)**
```
stuttertest run a1 --duration 90                       # baseline: KWin 6.7.5, triple buffering on
stuttertest run a3-mem --clock mem --duration 90
stuttertest run a3-gr --clock gr --duration 90
stuttertest run a3-pm-max --clock pm-max --duration 90
stuttertest run a3-pm-consistent --clock pm-consistent --duration 90
stuttertest run a3-p0 --clock p0 --duration 90
stuttertest run a3-p0ctl --clock p0ctl --duration 90
stuttertest run a1-2 --duration 90                     # baseline again: did anything drift?

stuttertest kwin set tb=off                            # log out/in
stuttertest run a2-tb-off --duration 90

stuttertest kwin set tb=default margin=3000            # log out/in
stuttertest run a4-margin3000 --duration 90
stuttertest kwin set margin=default                    # log out/in before Phase B
```

**Phase B: hybrid mode, NVIDIA composites.** Set `stuttertest kwin set gpu=nvidia`, keep the same lid state (lid closed, or `lidcheck=off` as above), log out and in. `stuttertest info` must show an NVIDIA render GPU.
```
stuttertest run b1 --duration 90
stuttertest run b3-p0 --clock p0 --duration 90
stuttertest run b3-p0ctl --clock p0ctl --duration 90
stuttertest run b3-mem --clock mem --duration 90
stuttertest kwin set gpu=default       # log out/in
```
If X11 apps flicker in this mode, note it; it doesn't affect the frame numbers.

**Phase C: BIOS dGPU-only.** The render GPU is NVIDIA automatically, and `p0ctl` is unavailable (no Intel GPU).
```
stuttertest run c1 --duration 90
stuttertest run c3-p0 --clock p0 --duration 90
stuttertest kwin set tb=off            # log out/in
stuttertest run c2-tb-off --duration 90
stuttertest kwin set tb=default
```
Then switch the BIOS back to **Hybrid**.

**Phase D: module type, then GSP.** Repeat `a1`, `a3-p0` and `b1` (with the Phase B setting) in each step:
```
./02-nvidia.sh 580-closed && reboot           # proprietary modules, GSP on   -> runs d1-a1, d1-a3-p0, d1-b1
./02-nvidia.sh 580-closed-gsp-off && reboot   # proprietary modules, GSP off  -> runs d2-a1, d2-a3-p0, d2-b1
./02-nvidia.sh 580-open && reboot             # back to the default
```
`./02-nvidia.sh status` after each reboot: "GSP Firmware Version" must read N/A in the GSP-off step.

**Phase E: driver 615 (comparison).** Avoid monitor power-cycles in this phase (#1392, §6).
```
./02-nvidia.sh 615-open && reboot      # repeat a1, a3-p0, a3-p0ctl, b1 as e-a1, e-a3-p0, e-a3-p0ctl, e-b1
./knobs.sh vblank on && reboot         # 615 only (option added in 610.43.02): repeat a1, b1 as e-vbl-a1, e-vbl-b1
./knobs.sh vblank off
./02-nvidia.sh 580-open && reboot      # back to the default
```

**Phase F: Dynamic Boost off.** `./knobs.sh powerd off`, repeat `a1` as `f-a1`, then `./knobs.sh powerd on`. Otherwise keep it in the same state for every run.

**Phase G, optional: other desktops.** Log into GNOME or COSMIC, dock, and run `stuttertest run g-gnome --smi --duration 90` with the same routine. There's no KWin frame log there, so it records your yes/no answers plus P-states.

**Phase V, optional: video playback (the separate I8 problem).** Only if video matters to you. Play the same local 4K file windowed (`mpv --loop --geometry=50%x50% <file>`) in Phase A and Phase B setups, as `v-a` and `v-b`. Phase B removes the Intel→NVIDIA copy for video too.

**How to read the results:**
- **Details: "ready but flipped late" near 100%, and both monitors late together far more often than "by chance":** the frames were rendered and copied in time, and something GPU-wide on the NVIDIA side delayed the flip (power state, memory clock, late flip events). Run 001 looked like this. If instead the late frames weren't ready, and the monitors are late independently, the time goes into rendering or the copy: compare Phase B. The logged flip time is when the driver *reported* the flip, so a late report and a late flip look the same in the log. Your yes/no tells them apart.
- **`a2-tb-off` clearly worse than `a1`:** triple buffering matters. Plasma ≥ 6.7.3 is the fix; your old TUXEDO install (6.6.x) lacked it. If the triple-buffered share stays near 0% in `a1`, triple buffering never engaged and this comparison tells you nothing.
- **`p0` fixes it and `p0ctl` doesn't:** it's NVIDIA's low-power latency (NV 4830125). That is evidence for [open-gpu-kernel-modules #650](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/650), and the workaround is a held clock or load while docked.
- **A lock or PowerMizer mode fixes it:** make it automatic with `testbed/clockfloor/install.sh`. Set `/etc/default/nvidia-clockfloor` to what the winning run used (`MEM_LOCK=<value>`, `GR_MIN=900`, or `METHOD=powermizer PM_MODE=max|consistent`), then `sudo systemctl start nvidia-clockfloor.service`. It only applies while docked on AC.
- **`d2` (GSP off) fixes it and `d1` (proprietary, GSP on) doesn't:** a firmware-path issue. If `d1` alone fixes it, it's the module flavour.
- **NVIDIA compositing (B) beats Intel (A) in hybrid mode:** keep `gpu=nvidia` for docked use.
- **`e-…` (615) clearly worse than the matching 580 runs:** a 615 regression; stay on 580 and add your data to #1391. If 615 is better, the newer driver helps.

## 6. Known risks and recovery

- **Driver 615 (Phase E only) and monitor power-cycles:** after a DisplayPort monitor power-cycles behind a dock or hub, KWin can hang waiting on the GPU firmware ([#1392](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1392); one report is an RTX 4070 laptop in hybrid mode). That includes automatic screen-off, which `install-testbed.sh` turns off on AC. If it hits:
  1. Press Alt+SysRq + S, U, B, a few seconds apart. `01-base.sh` enables exactly these three; holding the power button also works.
  2. After the reboot, go back to the default with `./02-nvidia.sh 580-open` and skip the rest of Phase E.
- **A login breaks after a `stuttertest kwin set` change:** unplug the dock and log in (the login script does nothing undocked), then `stuttertest kwin set gpu=default tb=default margin=default`.
- **A driver switch fails:**
  - `./02-nvidia.sh` restores the previous build settings when the package transaction fails.
  - `./02-nvidia.sh status`, the akmods output, and `/var/cache/akmods/<nvidia or nvidia-580xx>/*.log` show why.
  - `./02-nvidia.sh 580-open` returns to the default.
  - If the version lock gets in the way, run `./freeze.sh off`, then switch.
- **Microcode:** `stuttertest info` prints it. The newest for this CPU (06-b7-01) is 0x137; update the XMG BIOS if it's lower.

## 7. What to send back

- `stuttertest report`
- the `~/stuttertest/info-*.txt` files, or simply `tar czf stuttertest.tgz ~/stuttertest`
- anything odd you noticed during the runs (flicker, hangs, X11 app problems)
