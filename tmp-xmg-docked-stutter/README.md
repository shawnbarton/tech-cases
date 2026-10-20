# (temporary) XMG Fusion 15 docked stutter: work in progress

Working folder for diagnosing desktop stutter on an XMG Fusion 15 (E24), i9-14900HX plus RTX 4070 Laptop. The stutter shows when it's docked to two 4K monitors that are wired to the NVIDIA GPU. It started as a suspected relative of [cosmic-comp #1915](https://github.com/pop-os/cosmic-comp/issues/1915). It is meant to become a proper case write-up once the cause is confirmed.

**Start here: [TESTBED.md](TESTBED.md)**. It covers the Fedora KDE 44 install, setup scripts and the test campaign.

## Layout

| Path | What |
|---|---|
| `TESTBED.md` | Distro choice, install, setup, test campaign, what to send back |
| `testbed/setup/fedora/` | `01-base.sh` (update, RPM Fusion, tools), `02-nvidia.sh` (driver branch, open or proprietary modules, GSP on/off), `03-sessions.sh` (GNOME and COSMIC), `knobs.sh` (nvidia_drm vblank, Dynamic Boost), `edid-8bpc.sh` (8 bpc EDID override, until reboot or from boot) |
| `testbed/patterns/` | Test patterns for the static: `static-patterns.html` (Firefox, GPU-drawn) and `term-patterns.sh` (Konsole, CPU-drawn) |
| `testbed/setup/install-testbed.sh` | Installs the tools and KWin login script, sets Adaptive Sync to Never on the Dells, fixes the power profile |
| `testbed/bin/stuttertest` | Test harness: system report, KWin settings, timed test runs with per-test frame statistics, results table |
| `testbed/bin/kwin-perf-summary` | Summarizes KWin's frame timing log (`KWIN_LOG_PERFORMANCE_DATA`) into late frames and render time |
| `testbed/bin/stutter-analyze` | Where a run's late frames come from: rendering vs. after rendering, bursts, both monitors at once vs. chance, P-state changes (`stuttertest analyze`) |
| `testbed/bin/nv-powermizer` | Gets or sets the NVIDIA PowerMizer mode through NVML. Works on Wayland (driver ≥ 580.65.06) |
| `testbed/bin/dgpu-run` | Runs a program on the NVIDIA GPU (PRIME render offload) |
| `testbed/kwin/50-kwin-docked-gpu.sh` | Plasma login script: triple buffering, compositing GPU, safety margin, frame log (docked only) |
| `testbed/clockfloor/` | Optional service: NVIDIA clock lock only while docked on AC, with installer and uninstaller |
| `notes/plan-tuxedo-os.md` | Earlier analysis and plan for the TUXEDO OS install, superseded |
| `tests/` | Tests for all of the above against fake sysfs, NVML, nvidia-smi, KWin, dnf and akmods. `tests/run-all.sh` runs them with no GPU needed |

## Current understanding

Checked against KWin 6.7.5/6.8.0 and NVIDIA 580.178.04/615.78.08 source, with skeptical review (2026-10-20). Details: `notes/2026-10-20-analysis.md`.

**Stutter (late frames)**
- Late frames are real: the flip lands one vblank after KWin's target. It isn't just a late report. KWin's flip times on NVIDIA are software timestamps (`ktime_get()` when nvidia-drm sends the event; no DRM vblank support in 580, or in 615 by default).
- About half of all late frames are knock-ons of an earlier late frame.
- The rest are mostly the **first frame after a pause** of one or more refreshes: about 40% of those are late, against about 2% of back-to-back frames. The rate doesn't grow with longer pauses, so a deep power-state wake-up doesn't fit.
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
- It isn't a marginal DP link. DP scrambling changes the bit pattern of the same picture every frame, so random link errors would twinkle anywhere regardless of content. The record also shows static at 1080p60 and 4K30, where the link has plenty of margin.
- Static that stays while a window is on DP-2 and changes with it points to something deterministic on that connector's pixel path, or to an event triggered by redraws. On the path, that means NVIDIA's output at 30bpp, or the Thunderbolt/dock DP path.
- The cable swap only ruled out the cable and the monitor. The GPU head and output, the Thunderbolt tunnel and the dock port all stay tied to the connector.
- The 8 bpc test is valid. The kernel's EDID override reaches NVIDIA, which then drives the link at 24bpp after a modeset, and `/proc/driver/nvidia-modeset/heads` proves it (`edid-8bpc.sh`, `nv-heads`). The old Ubuntu attempt was only ever checked in sysfs, so it never proved 8 bpc.
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
