# My OBS patches

- **[2026-09-05] Vulkan multi-GPU capture and presentation synchronization:** Game Capture failed when a Vulkan application ran on a different GPU from DXGI adapter 0: OBS created the shared texture on the wrong GPU, its Vulkan import found no compatible memory type, and capture failed with `VK_ERROR_OUT_OF_DEVICE_MEMORY`. The patch selects the DXGI adapter matching the Vulkan device and makes presentation wait for OBS's capture copy to finish. See [`upstream-submission/`](upstream-submission/).
