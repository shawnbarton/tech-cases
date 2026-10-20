# (temporary) XMG Fusion 15 docked stutter: work in progress

Working folder for diagnosing desktop stutter on an XMG Fusion 15 (E24), i9-14900HX plus RTX 4070 Laptop. The stutter shows when it's docked to two 4K monitors that are wired to the NVIDIA GPU. It started as a suspected relative of [cosmic-comp #1915](https://github.com/pop-os/cosmic-comp/issues/1915). It is meant to become a proper case write-up once the cause is confirmed.

**Start here: [TESTBED.md](TESTBED.md)**. It covers the Fedora KDE 44 install, setup scripts and the test campaign.

## Layout

| Path | What |
|---|---|
| `TESTBED.md` | Distro choice, install, setup, test campaign, what to send back |
| `testbed/setup/fedora/` | `01-base.sh` (update, RPM Fusion, tools), `02-nvidia.sh` (driver branch, open or proprietary modules, GSP on/off), `03-sessions.sh` (GNOME and COSMIC), `knobs.sh` (nvidia_drm vblank, Dynamic Boost) |
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

- The stutter persisted in BIOS dGPU-only mode, where there are no cross-GPU copies. The leading suspects are therefore on the NVIDIA side, in every mode:
  - NVIDIA's acknowledged low-power vblank latency bug ([NV 4830125 / open-gpu-kernel-modules #650](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/650)), possibly together with memory-clock switching;
  - KWin before 6.7.3 disabling triple buffering on NVIDIA-driven outputs. The old TUXEDO install ran Plasma 6.6.
- Driver 595.58.03 and later have an open report of lag on NVIDIA-wired monitors of KDE laptops ([#1090](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1090)), and 615 has open multi-monitor regressions (#1391, #1392). The test bed therefore defaults to the 580 long-term branch and uses 615 only as a comparison.
- `prime-select` never changes which GPU KWin composites on. TUXEDO's Wayland dGPU mode only offloads apps, which adds a second copy.

## Runs so far

**001-first** (2026-10-20). Fedora KDE 44, KWin 6.7.5, driver 615.78.08 open (installed before the default moved to 580), hybrid mode with Intel compositing, lid open with the built-in display off, both Dells at 4K60. Not yet the Phase 0 app routine.
- Seen: stutter **no**, static corruption **yes**.
- Measured: 4.4% (DP-2) and 4.9% (DP-3) of frames late, almost all by one refresh. KWin triple-buffered 95–98% of frames.
- 94–95% of the late frames were ready in time: rendering *and* the copy to the NVIDIA GPU had finished a median 14–20 ms before the deadline. KWin's render time includes that copy (`multigpuswapchain.cpp` adds its time query to the frame). The delay is therefore in the commit/flip step, which is the NVIDIA driver's side.
- The late frames come in bursts (21 and 45 bursts, under 250 ms apart).
- Both Dells go late together. 31 of DP-2's 66 late frames had DP-3 late within one refresh, against about 2.5 by chance. The other way it was 26 of 49, against about 0.8. Chance is measured with the timing shifted 2–10 s, so it keeps the bursts. A GPU-wide event on the NVIDIA side fits that (low-power flip latency, NV 4830125, or a memory-clock change). Slow rendering of one monitor's content doesn't.
- Open: is this level of lateness below what's noticeable, or does the stutter need the apps from the case (Phase 0)? Does it come back without triple buffering (`a2-tb-off`)? The corruption is there on a current stack too.

**002-0-x11** (2026-10-20). Same setup but driver 580.178.04 open. Despite the name, random apps (Konsole, Dolphin, Firefox are all native Wayland). 60 s.
- Seen: stutter **not sure**, static **yes**: "Konsole causes static and screen blanking when dragged to DP-2. As does Dolphin. Firefox does not immediately appear to trigger the issue."
- Measured: 10.6% (DP-2) and 9.5% (DP-3) of frames late. 84% and 93% of them were ready in time, with a median 16–24 ms to spare.
- Both Dells were late together again: 44 of 78 against about 6 by chance, and 46 of 65 against about 3.
- Flip times jitter by about 30 µs between frames, so they're when the driver reported each flip, not hardware vblank stamps. Late flips land on the next vblank, 1.0 refresh late (a few 2–4).
- KWin 6.7 commits a finished frame about 2 ms before vblank (the safety margin). If its buffer's fence isn't signalled then, it moves the frame one refresh later (`drm_commit_thread.cpp`). A frame that finished early can therefore still miss its vblank. That happens if the NVIDIA side signals the copy late, commits slowly, or latches or reports the flip late.
- Run 002 isn't directly comparable with 001: different driver and different activity.
