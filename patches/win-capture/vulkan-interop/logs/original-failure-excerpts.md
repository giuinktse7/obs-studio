# Original failure excerpts

Source: reporter-provided messages from September 5, 2026. These are selected excerpts, not a preserved complete raw log.

## Vulkan import failure, stock OBS 32.2.2

```text
vkAllocateMemory(): pAllocateInfo->memoryTypeIndex is 1 but VkMemoryWin32HandlePropertiesKHR::memoryTypeBits is 0x0 with handleType VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT.
vkAllocateMemory(): pAllocateInfo->memoryTypeIndex is 0 but VkMemoryWin32HandlePropertiesKHR::memoryTypeBits is 0x0 with handleType VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT.
VUID-VkMemoryAllocateInfo-memoryTypeIndex-00645

11:26:08.917: [game-capture: 'Game Capture'] vk_shtex_init_vulkan_tex: failed to AllocateMemory (DEVICE_LOCAL): VK_ERROR_OUT_OF_DEVICE_MEMORY (-2)
11:26:08.917: [game-capture: 'Game Capture'] vk_shtex_init_vulkan_tex: failed to AllocateMemory (not DEVICE_LOCAL): VK_ERROR_OUT_OF_DEVICE_MEMORY (-2)
11:26:08.917: [game-capture: 'Game Capture'] vk_shtex_init_vulkan_tex: failed to allocate memory of any type
```

## D3D12 capture resize failure, stock OBS

```text
09:24:05.920:     BufferDesc.Width: 1282
09:24:05.920:     BufferDesc.Height: 720
09:24:06.029: [game-capture: 'Game Capture'] create_d3d12_tex: creation of d3d11 copy tex failed (0x80070057): The parameter is incorrect.
09:24:06.303: [game-capture: 'Game Capture'] capture window no longer exists, terminating capture
```

Application output:

```text
Vulkan redraw failed during vkQueuePresentKHR: ERROR_UNKNOWN
fatal Vulkan redraw error: ERROR_UNKNOWN
```

The D3D12 failure also persisted with the intermediate patched hook before successful Vulkan capture was established. Its internal cause is not established by these excerpts.
