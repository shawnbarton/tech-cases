# (temporary) XMG Fusion 15 docked stutter: work in progress

Working folder for diagnosing desktop stutter on an XMG Fusion 15 (E24), i9-14900HX plus RTX 4070 Laptop. The stutter shows when it's docked to two 4K monitors that are wired to the NVIDIA GPU. It started as a suspected relative of [cosmic-comp #1915](https://github.com/pop-os/cosmic-comp/issues/1915). It is meant to become a proper case write-up once the cause is confirmed.

**Start here: [TESTBED.md](TESTBED.md)**. It covers the Fedora KDE 44 install, setup scripts and the test campaign.

## Layout

| Path | What |
|---|---|
| `TESTBED.md` | Distro choice, install, setup, test campaign, what to send back |
| `testbed/setup/fedora/` | `01-base.sh` (update, RPM Fusion, tools), `02-nvidia.sh` (driver branch, open or proprietary modules, GSP on/off), `03-sessions.sh` (GNOME and COSMIC), `knobs.sh` (nvidia_drm vblank, Dynamic Boost, nvidia-modeset debug messages), `edid-8bpc.sh` (8 bpc EDID override, until reboot or from boot) |
| `testbed/patterns/` | Test patterns for the static: `static-patterns.html` (Firefox, GPU-drawn) and `term-patterns.sh` (Konsole, CPU-drawn); `workload.html`, the same screen activity for every A/B run |
| `testbed/setup/install-testbed.sh` | Installs the tools and KWin login script, sets Adaptive Sync to Never on the Dells, fixes the power profile |
| `testbed/bin/stuttertest` | Test harness: system report, KWin settings, timed test runs with per-test frame statistics, results table |
| `testbed/bin/kwin-perf-summary` | Summarizes KWin's frame timing log (`KWIN_LOG_PERFORMANCE_DATA`) into late frames and render time |
| `testbed/bin/stutter-analyze` | A run's late frames by kind (knock-on, after a pause, back-to-back), visible hitches, bursts, both monitors at once vs. chance, static marks, P-state changes (`stuttertest analyze`) |
| `testbed/bin/nv-heads` | What the NVIDIA display engine sends to each monitor: mode and pixel depth (30bpp/24bpp) |
| `testbed/trace/flipfence.bt` | Kernel trace of KWin's commits and NVIDIA's flip events (`stuttertest run --trace`) |
| `testbed/bin/nv-powermizer` | Gets or sets the NVIDIA PowerMizer mode through NVML. Works on Wayland (driver ≥ 580.65.06) |
| `testbed/bin/dgpu-run` | Runs a program on the NVIDIA GPU (PRIME render offload) |
| `testbed/kwin/50-kwin-docked-gpu.sh` | Plasma login script: triple buffering, compositing GPU, safety margin, software cursor, full repaints, frame log (docked only) |
| `testbed/clockfloor/` | Optional service: NVIDIA clock lock only while docked on AC, with installer and uninstaller |
| `notes/2026-10-20-analysis.md` | Source-checked analysis of runs 001–002 and the static, with references |
| `notes/plan-tuxedo-os.md` | Earlier analysis and plan for the TUXEDO OS install, superseded |
| `tests/` | Tests for all of the above against fake sysfs, NVML, nvidia-smi, KWin, dnf and akmods. `tests/run-all.sh` runs them with no GPU needed |

## Current understanding

Checked against KWin 6.7.5/6.8.0 and NVIDIA 580.178.04/615.78.08 source, with skeptical review (2026-10-20). Details: `notes/2026-10-20-analysis.md`.

**Stutter (late frames)**
- Late flips land on the vblank grid, exactly one refresh after KWin's target, not at jittery times. That points to a flip that latched late. A report delayed by exactly one vblank isn't ruled out yet; the kernel trace (Phase T) can tell them apart. KWin's flip times on NVIDIA are software timestamps (`ktime_get()` when nvidia-drm sends the event; no DRM vblank support in 580, or in 615 by default).
- About half of all late frames are knock-ons of an earlier late frame.
- Of the rest, most (pooled over both runs) are the **first frame after a pause** of one or more refreshes. Frames after a pause are late 24–43% of the time (28% and 24% in run 001, 41% and 43% in run 002), against 1–2% of back-to-back frames. The rate doesn't grow with longer pauses, so a deep power-state wake-up doesn't fit.
- Many late frames repeat a picture that didn't change, so they're invisible. The analyzer now counts the ones that delayed new content.
- Rendering cost is ruled out. Caveat: KWin's "render end" doesn't prove the frame was ready for the NVIDIA side. It leaves out the copy's wait and the time NVIDIA takes to signal it.
- Open candidates:
  - NVIDIA needs more than KWin's ~2.3 ms lead time for the first flip after a pause.
  - Cursor-only commits: nvidia-drm sends their completion event at once, and KWin re-times its next frame from it.
  - Flip events delivered late through NVIDIA's shared lock and worker thread. These carry the "both monitors late together" pattern.
  - KWin main-thread stalls. Konsole and Dolphin draw with the CPU, and KWin uploads their pictures on its main thread (udmabuf import is off by default on Intel and NVIDIA).
- Tests that tell these apart: a larger safety margin, a software cursor, and a kernel trace (Phase A/T). Clock locks are a weak test, because they don't stop power gating.
- The old TUXEDO install ran driver 595.71.05, which is in the range of the open lag report [#1090](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1090), and Plasma 6.6, which had triple buffering off on NVIDIA. 615 has its own regressions (#1391 blanking on memory-clock changes, #1392 hangs after a DP power-cycle). The test bed defaults to the 580 long-term branch.
- [#650](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/650) (low fps on dGPU-wired external monitors) is tracked as NVIDIA bug 4830125. NVIDIA has not published a cause or a fix.
- KWin 6.8.0 attaches the copy's fence to the commit on NVIDIA (IN_FENCE_FD). That is a future A/B once Fedora ships it.

**Static on DP-2**
- Random bit errors on a marginal DP link are unlikely to cause window-tied static. DP scrambling changes the bit pattern of the same picture every frame, so such errors would twinkle anywhere regardless of content. (That reasoning is from the scrambler's design; the VESA text wasn't read.) The record also shows static at 1080p60, which runs at a lower lane rate, and that argues against signal integrity.
- Static that stays while a window is on DP-2 and changes with it points to something deterministic, or to an event triggered by redraws. The candidates:
  - NVIDIA's 30bpp output for that connector;
  - the Thunderbolt tunnel or the dock's DP port handling 30-bit data;
  - bad pixels kept in the picture NVIDIA scans out.
- The cable swap only ruled out the cable and the monitor. The GPU head and output, the Thunderbolt tunnel and the dock port all stay tied to the connector.
- The 8 bpc test should work. Per the 580/615 source, the kernel's EDID override reaches NVIDIA, which then drives the link at 24bpp after a modeset, and `/proc/driver/nvidia-modeset/heads` shows it (`edid-8bpc.sh`, `nv-heads`). It hasn't been seen on this machine yet, and one forum report (382464) says the DRM override was ignored. The old Ubuntu attempt was only ever checked in sysfs, so it never proved 8 bpc.
- 615 also has `nvidia-modeset.max_output_color_depth=8`.
- Never tested and decisive for dock versus GPU side: a direct USB-C→DP cable, and a single monitor on that port.

- `prime-select` never changes which GPU KWin composites on. TUXEDO's Wayland dGPU mode only offloads apps, which adds a second copy.

## Runs so far

**001-first** (2026-10-20). Fedora KDE 44, KWin 6.7.5, driver 615.78.08 open (installed before the default moved to 580), hybrid mode with Intel compositing, lid open with the built-in display off, both Dells at 4K60. General use, not yet the app routine.
- Seen: stutter **no**, static **yes**.
- 4.4% (DP-2) and 4.9% (DP-3) of frames late, almost all by exactly one refresh, in bursts. Triple-buffered 95–98%.
- DP-2: 40 knock-on, 20 first-after-pause, 21 back-to-back. After a pause 28% late; back-to-back 1.2%.
- Both Dells late together far above chance (31/66 vs about 2.5). That pattern lives in the back-to-back frames.

**002-0-x11** (2026-10-20). Same, driver 580.178.04 open. Despite the name, random apps (Konsole, Dolphin, Firefox: all native Wayland). 60 s.
- Seen: stutter **not sure**, static **yes**:
  - "Konsole causes static and screen blanking when dragged to DP-2. As does Dolphin. Firefox does not immediately appear to trigger the issue."
  - "The static often stays as long as the window is on the other screen and changes as the window moves or changes. Blanking can occur in conjunction with the static."
- 10.6% and 9.5% late.
  - DP-2: 56 knock-on, 47 first-after-pause, 21 back-to-back. After a pause 41% late; back-to-back 2.1%.
  - DP-3: after a pause 43%; back-to-back 2.0%.
- The two runs differ in driver *and* activity (run 002 had more pauses), so they don't compare 580 with 615.
- DP-2 and DP-3 run slightly different modes (59.996 vs 59.997 Hz) although the monitors are identical. Does that follow the port?

**004-s-8bpc-konsole-dp2** (2026-10-20). Driver 580.178.04, after `edid-8bpc.sh try DP-2` (8 bpc EDID on DP-2). Konsole dragged onto DP-2 and back for 30 s.
- Seen: **no static and no blanking.** This is the first run without static under the trigger that brought it every time before.
- Earlier the same day, still at 30bpp, static appeared during the logout animation to the login screen. So it isn't tied to the session or to particular apps.
- Late frames unchanged: 6.3% and 5.5%. After a pause 25% and 27%; back-to-back 2.9% and 1.9%. Both Dells late together far above chance. The bit depth doesn't affect the stutter.
- Pending: the depth `try` reported (24bpp expected), and the control: `undo` to 30bpp, does the static come back, then `try` again.
