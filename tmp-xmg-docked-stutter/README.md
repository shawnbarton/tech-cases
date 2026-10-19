# (temporary) XMG Fusion 15 docked stutter: work in progress

Working folder for diagnosing desktop stutter on an XMG Fusion 15 (E24), i9-14900HX plus RTX 4070 Laptop. The stutter shows when it's docked to two 4K monitors that are wired to the NVIDIA GPU. It started as a suspected relative of [cosmic-comp #1915](https://github.com/pop-os/cosmic-comp/issues/1915). It is meant to become a proper case write-up once the cause is confirmed.

## Layout

| Path | What |
|---|---|
| `testbed/bin/stuttertest` | Test harness: system report, KWin settings, timed test runs with per-test frame statistics, results table |
| `testbed/bin/kwin-perf-summary` | Summarizes KWin's frame timing log (`KWIN_LOG_PERFORMANCE_DATA`) into late frames and render time |
| `testbed/bin/nv-powermizer` | Gets or sets the NVIDIA PowerMizer mode through NVML. Works on Wayland (driver ≥ 580.65.06) |
| `testbed/bin/dgpu-run` | Runs a program on the NVIDIA GPU (PRIME render offload) |
| `testbed/kwin/50-kwin-docked-gpu.sh` | Plasma login script: triple buffering on/off and compositing GPU while docked |
| `testbed/clockfloor/` | Optional service: NVIDIA clock lock only while docked on AC, with installer and uninstaller |
| `testbed/setup/` | Distro install and setup scripts *(in progress)* |
| `notes/plan-tuxedo-os.md` | Earlier analysis and plan for the TUXEDO OS install, superseded by the test-bed setup |
| `tests/` | Tests for all of the above against fake sysfs, NVML, nvidia-smi and KWin. `tests/run-all.sh` runs them with no GPU needed |

## Current understanding

- The stutter persisted in BIOS dGPU-only mode, where there are no cross-GPU copies. The leading suspects are therefore on the NVIDIA side, in every mode:
  - NVIDIA's acknowledged low-power vblank latency bug ([NV 4830125 / open-gpu-kernel-modules #650](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/650)), possibly together with memory-clock switching;
  - KWin before 6.7.3 disabling triple buffering on NVIDIA-driven outputs.
- `prime-select` never changes which GPU KWin composites on. TUXEDO's Wayland dGPU mode only offloads apps, which adds a second copy.
