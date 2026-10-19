# XMG Fusion 15 (E24): docked stutter, fix plan

*2026-10-19, final after two review rounds. Covers I6/I9 (docked UI and cursor stutter) and I8 (video in on-demand mode). The dock-port corruption (I3) is a separate bug and is not covered here.*

**Who does what.** You run the tests and report the numbers; I adjust the plan. Every change is undone by one command, by logging out, or by unplugging the dock.

Tools in this folder (tested against fake sysfs and driver setups, not yet on your machine):
- `kwin/50-kwin-docked-gpu.sh`: login script. It does nothing until you set an option, and nothing at all when undocked.
- `kwin/kwin-perf-summary`: turns KWin's frame log into "% late frames".
- `clockfloor/`: clock-lock service with installer and uninstaller, plus `nv-powermizer`.

## 1. What is happening

**Your BIOS dGPU-only test is the key evidence.** In that mode there's no Intel GPU and no copy between GPUs, and it still stuttered. So cross-GPU copies are not the root cause. They add load, which may be why on-demand mode reduced the stutter, but they aren't the core problem.

What is left applies in **every** mode, because the NVIDIA GPU always drives the Dells:

1. **NVIDIA low-power latency.**
   - NVIDIA acknowledged NV bug 4830125: at low power the driver delivers vblank ("screen just refreshed") events to the compositor late, so frames miss their slot. Per NVIDIA, the stutter goes away at P0.
   - It's tracked in [open-gpu-kernel-modules #650](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/650). The closed #777 linked its leftover stutter to it.
   - NVIDIA has reported partial improvements for stutter when GSP is in use (#724), but no fix for 4830125.
   - Clock locks are **not** known to prevent it. Your own 6001/1500 lock still sat at P4, and a #650 user reports locks "do not help much".
   - Your memory-clock swings (8001↔6001↔810 MHz) may be a separate hitch source; NVIDIA hasn't confirmed that.
2. **No spare frame in KDE on NVIDIA monitors.** KWin before **6.7.3** turns triple buffering off for every output driven by an NVIDIA GPU. That covers the Dells in every mode, including dGPU-only. Triple buffering keeps one extra finished frame ready, so a single late frame isn't visible. Users in #650 report it helps on hybrid setups, and KWin enabled it on NVIDIA by default in 6.7.3.

Your dGPU-only test ran with neither lever: KWin was presumably older than 6.7.3, and there were no clock changes. Those two are what this plan tests.

Smaller factors:

- **KWin before 6.6.5** has KDE bug 517987, which is your I4 error flood. With Intel compositing it also forces a **software cursor**, so every cursor move needs a new composited frame plus a copy to NVIDIA.
- **Polling.** With GSP firmware (always on with the open modules), GPU queries are handled by the GSP. Polling tools can add stutter (#777). The worst case was fixed in 570.124, so treat this as a variable to rule out, not a known cause.
- **Video in on-demand mode:**
  - the small iGPU composites two 4K screens;
  - Ubuntu's free Intel media driver has no AV1 decode on Raptor Lake, so YouTube 4K (usually AV1) is decoded by the CPU.

**Background: `prime-select` never decides where KDE composites.**
- KWin picks its compositing GPU at login: the first entry in `KWIN_DRM_DEVICES` if that is set, otherwise the GPU with the internal panel, which is Intel in hybrid mode.
- TUXEDO's dGPU ("performance") mode on Wayland only exports app offload variables (`__NV_PRIME_RENDER_OFFLOAD`, `__GLX_VENDOR_LIBRARY_NAME`, `__VK_LAYER_NV_optimus`, `DRI_PRIME`) and turns off NVIDIA runtime power management.
- So performance mode without `KWIN_DRM_DEVICES` means: apps on NVIDIA, KWin on Intel, frames crossing twice.

## 2. Step 0: collect facts (read-only, 3 minutes)

```
kwin_wayland --version; Xwayland -version 2>&1 | head -1
prime-select query; ls -l /etc/profile.d/tuxedo-dgpu-default.sh 2>/dev/null
grep -H . /sys/class/drm/card*-eDP-*/status
qdbus6 org.kde.KWin /KWin org.kde.KWin.supportInformation | grep -iE '^OpenGL (vendor|renderer)'
systemctl --user show-environment | grep KWIN_
grep -Hs KWIN_ /etc/environment ~/.config/environment.d/* ~/.config/plasma-workspace/env/* ~/.profile ~/.bash_profile /etc/profile.d/*
nvidia-smi --query-gpu=driver_version,pstate --format=csv
grep -E 'PreserveVideoMemoryAllocations|UseKernelSuspendNotifiers' /proc/driver/nvidia/params; systemctl is-enabled nvidia-suspend.service nvidia-resume.service
flatpak list --runtime 2>/dev/null | grep -i nvidia
```

If you remember: which `KWIN_DRM_DEVICES` value did you use when I4/I5 "worked"? The by-path value in the record can't work (§8).

## 3. Step 1: clean up

1. Stay in **on-demand** mode (`prime-select query` → `on-demand`).
2. Remove every `KWIN_*` line found in Step 0: `/etc/environment`, `environment.d`, profile files. Then reboot.
   - The by-path value in the record is malformed.
   - `/etc/environment` also reaches the login screen's own KWin.
3. Don't keep `KWIN_DRM_PREFER_COLOR_DEPTH` (no effect on nvidia-drm), `KWIN_DRM_NO_AMS` (loses atomic modesetting, triple buffering and smooth cursor updates) or `KWIN_DRM_NO_DIRECT_SCANOUT`.
4. During every test, close GPU-polling tools:
   - the **TUXEDO Control Center dashboard window** (its daemon runs `nvidia-smi` every 2 s while the dashboard is visible)
   - system-monitor GPU widgets, nvtop, btop, mangohud
   - any `nvidia-smi -l` loop
5. If KWin is older than **6.6.5**: `sudo apt update && sudo apt full-upgrade`, then **reboot**. A driver update without a reboot leaves a driver/library mismatch.
6. **Built-in display:** keep it off while docked, as you already do. Disable `eDP-1` in Display settings once while docked **with the lid open**. KWin stores lid-open and lid-closed layouts separately for each monitor combination, so the panel then stays off either way.
7. Install the login script:
   ```
   mkdir -p ~/.config/plasma-workspace/env
   cp kwin/50-kwin-docked-gpu.sh ~/.config/plasma-workspace/env/
   ```

**Measuring each step.**
1. Set `KD_PERF_LOG=1` in the installed script. Log out and back in docked, and use the desktop for a few minutes, including the stutter cases.
2. Before the next logout, move the CSVs aside, because KWin overwrites them at every login: `mkdir -p ~/perf-<step> && mv ~/kwin\ perf\ statistics\ *.csv ~/perf-<step>/`
3. Compare with `kwin/kwin-perf-summary ~/perf-<step>/*.csv`. It reports the share of late frames and the render time, which includes the multi-GPU copy.

## 4. Step 2: baseline, then triple buffering

1. **Baseline:** script at its defaults (`KD_GPU=` and `KD_TRIPLE_BUFFERING=` empty, `KD_REQUIRE_LID_CLOSED=1` untouched) plus `KD_PERF_LOG=1`. Record `~/perf-baseline`.
2. **Triple buffering** (skip if KWin is 6.7.3 or newer, where it's already on):
   - Set `KD_TRIPLE_BUFFERING=1`.
   - Set Adaptive Sync to **Never** on both Dells; KWin only triple-buffers in normal vsync mode.
   - Log out and back in, and record `~/perf-tb`.
   - Caveat: with Intel compositing, KWin 6.6.x lacks the multi-GPU sync fixes from 6.7.0, and KWin had disabled this combination because of glitches and an occasional frozen display.
   - If a Dell flickers or freezes, unplug the dock and log in (the script does nothing undocked), then set `KD_TRIPLE_BUFFERING=` back to empty.

## 5. Step 3: GPU power tests, then automate the winner

Run docked, on AC, in the best setup so far. Do each test for about 60 s of window dragging, cursor over the empty desktop, and video. Log at 500 ms and watch the **pstate** column, then repeat the feel test with logging stopped:

```
nvidia-smi -q -d SUPPORTED_CLOCKS | less
nvidia-smi --query-gpu=timestamp,pstate,clocks.mem,clocks.gr,power.draw,clocks_event_reasons.active --format=csv -lms 500 | tee ~/clk-<test>.csv
```

| Test | Set | Reset |
|---|---|---|
| A. baseline | nothing | |
| B. memory clock lock | `sudo nvidia-smi -lmc 8001,8001` | `sudo nvidia-smi -rmc` |
| C. graphics floor | `sudo nvidia-smi -lgc 900,<clocks.max.graphics>` | `sudo nvidia-smi -rgc` |
| D. PowerMizer "consistent" | `sudo clockfloor/nv-powermizer consistent` | `sudo clockfloor/nv-powermizer adaptive` |
| E. PowerMizer "max" | `sudo clockfloor/nv-powermizer max` | as D |
| F. NVIDIA's diagnostic: forced P0 | `dgpu-run env __GL_SYNC_TO_VBLANK=0 glxgears`. Keep the window small, and confirm P0 in the log. | close it |

How to read the results:
- **F fixes it but B–E don't:** the low-power state is the cause, and clock locks don't reach it. Add your data to #650. See the last section for what remains.
- **B or C fixes it:** check the pstate column before concluding why, since a lock can change the P-state too. Then step `MEM_LOCK` down through the supported values while it stays fixed.
- **D/E:** run `nv-powermizer` again with no argument. If it shows `adaptive`, the mode doesn't persist once the setting process exits, so use B/C. The NVML PowerMizer API exists since driver 580.65.06; whether this GeForce laptop accepts it is what D/E tests.
- **Nothing helps, including F:** the cause is elsewhere (KWin scheduling or the copy path). Send me the perf summaries.
- Note `power.draw` idle for the winner against the baseline. That is the price.

**These are locks, not just floors.**
- `-lmc X,X` also **caps** the memory clock at X.
- PowerMizer "consistent" caps the GPU at base clocks.
- Only `GR_MIN` alone is a pure floor.
- For gaming while docked, use `MEM_LOCK=8001`, or pause the service (below).

**Automate** (AC and docked only; released on battery, undock or an invalid setting; re-applied after resume and when settings change):
1. Install: `sudo clockfloor/install.sh`. Settings live in `/etc/default/nvidia-clockfloor`: `METHOD=locks|powermizer`, `MEM_LOCK`, `GR_MIN`, `PM_MODE`.
2. After editing the settings: `sudo systemctl start nvidia-clockfloor.service`.
3. Pause (for example for gaming), which releases everything and keeps it off through udev, timer and resume runs:
   `sudo sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/nvidia-clockfloor && sudo systemctl start nvidia-clockfloor.service`
4. Resume afterwards: the same command with `ENABLED=1`.
5. Log: `journalctl -t nvidia-clockfloor -b`
6. Check that the dock's PD charging counts as AC: `systemd-ac-power -v`. The service uses the same check.
7. Remove: `sudo clockfloor/install.sh --uninstall`, or `--purge` to also delete the settings.

## 6. Step 4: video (on-demand)

- Install `intel-media-va-driver-non-free` for AV1 decode on the iGPU.
- Check with `vainfo --display drm --device /dev/dri/renderD128`, after confirming via `ls -l /dev/dri/by-path/` that renderD128 is the Intel node.
- In Firefox, check `about:support` → Media for hardware decoding.
- If 4K AV1 still struggles, an extension that forces VP9/H.264 is the quick workaround.
- Don't use `nvidia-vaapi-driver` with Intel compositing: importing NVIDIA-decoded frames into Intel can hang the Intel GPU (open-gpu-kernel-modules #1037).

## 7. Optional, only if the measurements point there: KWin composites on NVIDIA while docked

Your dGPU-only test already covered "NVIDIA composites, no copies", and it didn't fix the stutter on its own. Revisit this only if Steps 2–3 fix the stutter and on-demand video stays poor. With KWin on NVIDIA, video on the Dells needs no copies.

1. Stay in on-demand mode. TUXEDO's dGPU mode exports `DRI_PRIME=1` and the offload variables, which conflict with this setup.
2. Check Xwayland. If it's older than **24.1**, X11 apps rendered on NVIDIA (Discord, Steam) have no explicit sync and may flicker. Check them after switching, and run Electron apps as native Wayland (`--ozone-platform=wayland`) where possible.
3. **Flatpaks:** they need the NVIDIA GL runtime matching your driver (`flatpak update` installs it), otherwise they can end up on software rendering.
4. In the installed script set `KD_GPU=nvidia`, and keep `KD_REQUIRE_LID_CLOSED=1` and the Step 2–3 settings.
   - The script resolves both GPUs to `/dev/dri/cardN` at each login.
   - It skips the switch if the lid is open or the NVIDIA module and libraries don't match.
5. Log in docked with the lid closed. Verify:
   - `qdbus6 org.kde.KWin /KWin org.kde.KWin.supportInformation | grep -i 'OpenGL renderer'` names NVIDIA.
   - `nvidia-smi` lists plasmashell and your browser.
6. Suspend and resume once while docked. If the screen comes back corrupted:
   - add `options nvidia NVreg_PreserveVideoMemoryAllocations=1` in `/etc/modprobe.d/`
   - enable `nvidia-suspend`, `nvidia-resume` and `nvidia-hibernate`
   - run `update-initramfs -u` and reboot.
7. Record `~/perf-nvidia` and keep this setup only if it beats Steps 2–3.

Rules for this setup:
- Log out **before undocking**, and log in again after docking.
- In Firefox on NVIDIA, hardware decode is blocked by default; `nvidia-vaapi-driver` with `LIBVA_DRIVER_NAME=nvidia MOZ_DISABLE_RDD_SANDBOX=1` (not the snap) is the opt-in.

**Recovery (any step).**
1. **Easiest:** unplug the dock (or power off the Dells) and log in. The script then does nothing. Move it out of `~/.config/plasma-workspace/env/`.
2. **Frozen:** press Alt+SysRq + S, U, B (Ubuntu allows only these), or hold the power button.
3. **Text console (Ctrl+Alt+F3):** it appears only on the internal panel, so open the lid.

## If Step 3 shows the low-power state is the cause and nothing reaches it

- **Plasma 6.7.3+ / 6.8,** when TUXEDO ships it: triple buffering on NVIDIA by default and multi-GPU sync fixes. 6.8.0 has one reported NVIDIA-first regression (KDE 527163), which is relevant only to the optional Step 7.
- **Newer NVIDIA drivers:** watch #650 for a fix to 4830125.
- **Fallback:** F itself (a tiny background load) is a crude but working stopgap while docked on AC, at a power cost.

## Don't

- Use `RMForcePstate`. NVIDIA calls it test-only, and it broke 240 Hz mode validation on an RTX 4060 laptop.
- Use `nvidia-smi -lmcd`. It applies at every driver load, battery included.
- Use `__GL_ExperimentalPerfStrategy=1`. It makes downclocking more aggressive.
- Put `DRI_PRIME` or offload variables in global environment files.
- Write an unescaped by-path `KWIN_DRM_DEVICES` anywhere.

## 8. Corrections to the record

1. **§6:** "Performance mode: desktop renders on NVIDIA" is only true while a valid NVIDIA-first `KWIN_DRM_DEVICES` is set. `prime-select` never moves KWin. TUXEDO dGPU mode also disables NVIDIA runtime power management.
2. **I4:** `KWIN_DRM_DEVICES=/dev/dri/by-path/pci-0000:01:00.0-card:/dev/dri/by-path/pci-0000:00:02.0-card` is malformed.
   - KWin splits the list on every unescaped `:`, so it becomes `pci-0000`, `01`, `00.0-card`, …
   - KWin then finds no GPU and the DRM backend fails to start.
   - Escaped (`pci-0000\:01\:00.0-card:…`) it works on 6.6. The login script instead resolves `/dev/dri/cardN` at each login, which also avoids a by-path bug in 6.8.0 (KDE 527309).
3. **I4:** the error flood is KDE bug **517987** (fixed in KWin 6.6.5, commits 413face7 and 64d60890), not 491751 or 512792. It also caused a software-cursor fallback.
4. **I4 / §4:** `KWIN_DRM_PREFER_COLOR_DEPTH` only sets the connector's "max bpc" property, which nvidia-drm doesn't expose. "No effect" is the expected result, and the 10-bit framebuffer format is chosen separately.
5. **I7:** PowerMizer is settable on Wayland now.
   - nvidia-settings sets it through NVML since 580.65.06, and 590.44.01 fixed the Wayland dropdown.
   - Ubuntu noble's nvidia-settings (510.47.03) is too old, so `clockfloor/nv-powermizer` calls NVML directly.
   - The old `PowerMizerEnable` registry dwords are indeed gone.
6. **I6:** 1 s `nvidia-smi` polling can itself perturb the GPU with GSP firmware. Prefer KWin's frame log for judging stutter.

## 9. Upstream

- **NVIDIA:** add your before/after data, especially test F versus B–E and the dGPU-only result, to [open-gpu-kernel-modules #650](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/650) (NV bug 4830125).
- **TUXEDO:** ask for KWin ≥ 6.7.3 (triple buffering on NVIDIA). Also point out that their Wayland dGPU mode only offloads apps, so KWin keeps compositing on Intel, and that it also turns off runtime PM.
- **cosmic-comp #1915:** the same NVIDIA-side causes apply to COSMIC, which also has no triple buffering at all (a `TODO` in its source). It additionally flips between rendering on NVIDIA (empty workspace) and Intel plus a copy (windows open), which matches your I9 observation.
