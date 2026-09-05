# Vulkan multi-GPU capture and presentation synchronization

This locally applied OBS patch fixes Game Capture for Vulkan applications that render on a different GPU from DXGI adapter 0.

## Failure

The Vulkan hook always created its D3D11 shared texture on adapter 0. On an Intel UHD 770 / NVIDIA RTX 4070 system, it therefore created the texture on Intel and tried to import it into Vulkan on NVIDIA. The import reported no compatible memory types and failed with `VK_ERROR_OUT_OF_DEVICE_MEMORY`.

Fixing the import exposed a second issue: OBS submitted its capture copy and layout transitions, but presentation waited only for the application's rendering. Synchronization validation reported `PRESENT_AFTER_WRITE`, and repeated resizing or minimizing and restoring could crash the captured application.

Before the Vulkan fix, OBS also fell back to D3D12 capture for the SRGB application and failed while recreating the capture texture after a resize. The D3D12 path is unchanged.

## Fix

The hook now selects the D3D11 adapter using the Vulkan device's Windows LUID, enables `VK_KHR_external_memory_win32`, and checks the shared handle's compatible memory types before allocation. Presentation now also waits on a per-swapchain-image semaphore signaled after OBS's capture copy completes.

## Verification

The patch was tested with a resizable Vulkan application using an SRGB swapchain and a standalone Vulkan 1.3 UNORM reproducer with synchronization validation enabled. Vulkan capture succeeded on the RTX 4070, remained active through repeated resize and minimize/restore cycles, and produced no validation errors in the final logs.

The issue was originally reproduced with OBS 32.2.2. The patch was tested against commit `6b3e550729f125b6c5b3767df88c08f5aef9d264`.

## Supporting material

- `logs/test-application-output.txt` and `logs/test-application-obs-output.txt`: final resizable Vulkan application test, approximately 14:01 on September 5, 2026.
- `logs/obs_capture_repro_output.txt` and `logs/obs_capture_repro_obs_output.txt`: final UNORM reproducer test, approximately 13:59–14:00.
- `logs/intermediate-present-hazard.log`: loader/application log from after adapter/import changes but before semaphore changes. Contains the presentation synchronization warnings.
- `logs/original-failure-excerpts.md`: earlier allocation and D3D12 resize failures quoted from the reporter's messages; not a complete raw log.
- `reproducer/main.odin`: standalone reproducer source snapshot using only Odin core/vendor libraries.

The logs retain their original diagnostic output, with the local application name replaced by `test-application`. The test application's OBS log covers the capture session; the reproducer's OBS log also includes startup and system information.

## Additional environment details

- Windows 11 25H2 (build 26200.9168).
- Intel Core i7-14700K, 32 GB RAM; RTX 4070 with 12 GB VRAM (PCI `10de:2786`); Intel UHD 770 (PCI `8086:a780`).
- NVIDIA driver 591.86, Vulkan 1.4.325; Intel driver 32.0.101.7082, Vulkan 1.4.323; Vulkan SDK 1.4.357.0.
- HAGS enabled. OBS ran without administrator privileges, in portable mode.
- Built with VS 2026 and CMake 4.4.3, x64 RelWithDebInfo. Scripting was disabled to work around an unrelated Lua build error.
- The patched build identifies itself as `32.2.1-66-g6b3e55072-modified`.

The hook matches NVIDIA to DXGI index 1, LUID `00000000:0000fb9a`. OBS's startup list calls NVIDIA adapter 0: that list has a different order from the hook's DXGI enumeration.

## Review notes

The patch contains two related fixes: adapter/import handling and capture/presentation synchronization. They can be split for review.

The semaphore change preserves the application's presentation `pNext` and `pResults`. Semaphores remain alive across capture stop/start and are released with the swapchain. Please pay particular attention to retirement when an application does not use presentation-completion fences.

Testing covers short manual sessions on one Intel/NVIDIA system. Other GPU combinations, multiple swapchains in one present call, device loss, and presentation failure recovery remain untested.

## Reproduce and verify

On Windows with a Vulkan 1.3-capable discrete GPU, Vulkan SDK validation layers, and Odin installed, run from this folder in Git Bash:

```bash
odin build reproducer -out:obs_capture_repro.exe -debug
env -u DISABLE_VULKAN_OBS_CAPTURE -u VK_LOADER_LAYERS_DISABLE \
  ./obs_capture_repro.exe --case unorm 2>&1 | tee repro-test.log
```

In OBS, add Game Capture targeting the reproducer. Record, repeatedly resize/release, minimize/restore, and toggle capture off/on. Close the reproducer and save the OBS log. Repeat with `--case baseline` for SRGB coverage. Confirm the selected Vulkan GPU and the hook's matched LUID, `vulkan shared texture capture successful`, and no validation errors. The submitted final reproducer evidence is for `unorm`; the separate application log supplies SRGB coverage.

## Building and deploying the test hook

From a configured OBS checkout, apply the patch and build on Windows:

```bash
git apply --check /path/to/obs-vulkan-capture.patch
git apply /path/to/obs-vulkan-capture.patch
cmake --build --preset windows-x64 --target graphics-hook --parallel 1
```

Close OBS and all applications loading its Vulkan layer before replacing the shared hook. Portable OBS still uses the ProgramData hook, and its version-based updater may not replace a rebuilt DLL with the same version. Back up that DLL before the first replacement:

```bash
cp -n /c/ProgramData/obs-studio-hook/graphics-hook64.dll \
  /c/ProgramData/obs-studio-hook/graphics-hook64.dll.before-patch
cp build_x64/rundir/RelWithDebInfo/data/obs-plugins/win-capture/graphics-hook64.dll \
  /c/ProgramData/obs-studio-hook/graphics-hook64.dll
sha256sum build_x64/rundir/RelWithDebInfo/data/obs-plugins/win-capture/graphics-hook64.dll \
  /c/ProgramData/obs-studio-hook/graphics-hook64.dll
```

The hashes must match. Restart OBS, then the test application. If the DLL is busy, close the process that still has it loaded and retry.
