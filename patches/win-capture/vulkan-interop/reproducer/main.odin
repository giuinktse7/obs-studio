package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "vendor:glfw"
import vk "vendor:vulkan"

MAX_PHYSICAL_DEVICES    :: 16
MAX_INSTANCE_EXTENSIONS :: 512
MAX_DEVICE_EXTENSIONS   :: 512
MAX_SURFACE_FORMATS     :: 64
MAX_PRESENT_MODES       :: 16
MAX_SWAPCHAIN_IMAGES    :: 8
INVALID_QUEUE_FAMILY    :: max(u32)
OVERSIZED_HEADROOM      :: u32(256)

Repro_Case :: enum {
	Baseline,
	Unorm,
	Mailbox,
	Scaling,
	Oversized,
	Present_Fences,
}

Queue_Families :: struct {
	graphics: u32,
	present:  u32,
}

Swapchain :: struct {
	handle:        vk.SwapchainKHR,
	format:        vk.Format,
	extent:        vk.Extent2D,
	present_mode:  vk.PresentModeKHR,
	scaling:       vk.PresentScalingFlagsKHR,
	images:        [MAX_SWAPCHAIN_IMAGES]vk.Image,
	present_ready: [MAX_SWAPCHAIN_IMAGES]vk.Semaphore,
	present_complete:         [MAX_SWAPCHAIN_IMAGES]vk.Fence,
	present_complete_pending: [MAX_SWAPCHAIN_IMAGES]bool,
	image_count:   u32,
	generation:    u64,
}

Repro :: struct {
	scenario:                        Repro_Case,
	window:                          glfw.WindowHandle,
	instance:                        vk.Instance,
	debug_messenger:                 vk.DebugUtilsMessengerEXT,
	surface:                         vk.SurfaceKHR,
	physical_device:                 vk.PhysicalDevice,
	device:                          vk.Device,
	queues:                          Queue_Families,
	graphics_queue:                  vk.Queue,
	present_queue:                   vk.Queue,
	command_pool:                    vk.CommandPool,
	command_buffer:                  vk.CommandBuffer,
	image_acquired:                  vk.Semaphore,
	frame_complete:                  vk.Fence,
	swapchain:                       Swapchain,
	resize_pending:                  bool,
	swapchain_out_of_date:           bool,
	surface_maintenance_extension:   cstring,
	swapchain_maintenance_extension: cstring,
}

main :: proc() {
	repro_case, case_valid := parse_repro_case(os.args)
	if !case_valid {
		fmt.eprintln(
			"Usage: obs_capture_repro.exe [--case baseline|unorm|mailbox|scaling|oversized|present-fences]",
		)
		os.exit(2)
	}

	if !glfw.Init() {
		fmt.eprintln("GLFW initialization failed")
		os.exit(1)
	}

	if !glfw.VulkanSupported() {
		fmt.eprintln("GLFW reports that Vulkan is unavailable")
		glfw.Terminate()
		os.exit(1)
	}

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, true)
	window := glfw.CreateWindow(1280, 720, "OBS Vulkan Capture Reproducer", nil, nil)
	if window == nil {
		fmt.eprintln("GLFW window creation failed")
		glfw.Terminate()
		os.exit(1)
	}

	repro := Repro {
		scenario       = repro_case,
		window         = window,
		resize_pending = true,
	}
	glfw.SetWindowUserPointer(window, &repro)
	glfw.SetFramebufferSizeCallback(window, framebuffer_size_callback)

	if !initialize_vulkan(&repro) {
		shutdown_vulkan(&repro)
		glfw.DestroyWindow(window)
		glfw.Terminate()
		os.exit(1)
	}

	log_active_configuration(&repro)
	fmt.println("Start OBS Game Capture, then repeatedly resize and release the window; close the window to finish")

	success := run_reproducer(&repro)
	shutdown_vulkan(&repro)
	glfw.DestroyWindow(window)
	glfw.Terminate()
	if !success {
		os.exit(1)
	}
}

parse_repro_case :: proc(args: []string) -> (Repro_Case, bool) {
	selected := Repro_Case.Baseline
	case_seen := false

	for index := 1; index < len(args); index += 1 {
		if args[index] != "--case" || case_seen || index + 1 >= len(args) {
			return {}, false
		}

		switch args[index + 1] {
		case "baseline":  selected = .Baseline
		case "unorm":     selected = .Unorm
		case "mailbox":   selected = .Mailbox
		case "scaling":   selected = .Scaling
		case "oversized": selected = .Oversized
		case "present-fences": selected = .Present_Fences
		case: return {}, false
		}
		case_seen = true
		index += 1
	}

	return selected, true
}

repro_case_name :: proc(repro_case: Repro_Case) -> string {
	switch repro_case {
	case .Baseline: return "baseline"
	case .Unorm:    return "unorm"
	case .Mailbox:  return "mailbox"
	case .Scaling:  return "scaling"
	case .Oversized: return "oversized"
	case .Present_Fences: return "present-fences"
	}
	return "unknown"
}

case_uses_mailbox :: proc(repro_case: Repro_Case) -> bool {
	return(
		repro_case == .Mailbox ||
		repro_case == .Scaling ||
		repro_case == .Oversized ||
		repro_case == .Present_Fences \
	)
}

case_uses_scaling :: proc(repro_case: Repro_Case) -> bool {
	return(
		repro_case == .Scaling ||
		repro_case == .Oversized ||
		repro_case == .Present_Fences \
	)
}

case_uses_oversized_extent :: proc(repro_case: Repro_Case) -> bool {
	return repro_case == .Oversized || repro_case == .Present_Fences
}

case_uses_present_fences :: proc(repro_case: Repro_Case) -> bool {
	return repro_case == .Present_Fences
}

case_surface_format :: proc(scenario: Repro_Case) -> vk.Format {
	if scenario == .Unorm {
		return .B8G8R8A8_UNORM
	}
	return .B8G8R8A8_SRGB
}

log_active_configuration :: proc(repro: ^Repro) {
	fmt.printf("Requested case: %s\n", repro_case_name(repro.scenario))
	fmt.println("Vulkan API: 1.3; validation: enabled; synchronization validation: enabled")
	fmt.printf("Device extensions: %s", vk.KHR_SWAPCHAIN_EXTENSION_NAME)
	if repro.swapchain_maintenance_extension != nil {
		fmt.printf(", %s", repro.swapchain_maintenance_extension)
	}
	fmt.println()
	if repro.surface_maintenance_extension != nil {
		fmt.printf(
			"Scaling instance extensions: %s, %s\n",
			vk.KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME,
			repro.surface_maintenance_extension,
		)
	}
	fmt.printf("Requested swapchain format: %v; color space: SRGB_NONLINEAR\n", case_surface_format(repro.scenario))
	if case_uses_oversized_extent(repro.scenario) {
		fmt.println("Extent policy: retained window extent + 256 pixels")
	} else {
		fmt.println("Extent policy: exact window extent")
	}
	fmt.printf("Presentation fences: %s\n", case_uses_present_fences(repro.scenario) ? "enabled" : "disabled")
	fmt.println("Excluded: deferred retirement")
	fmt.println("Determine the OBS capture backend from the matching OBS log")
}

run_reproducer :: proc(repro: ^Repro) -> bool {
	window := repro.window
	for !bool(glfw.WindowShouldClose(window)) {
		glfw.PollEvents()

		width, height := glfw.GetFramebufferSize(window)
		if width == 0 || height == 0 {
			glfw.WaitEvents()
			continue
		}

		if repro.resize_pending {
			recreation_required := repro.swapchain_out_of_date ||
				swapchain_extent_requires_recreation(repro, u32(width), u32(height))
			if recreation_required {
				if result := recreate_swapchain(repro); result != .SUCCESS {
					log_vulkan_failure("recreate_swapchain", result)
					return false
				}
			}
			repro.resize_pending = false
			repro.swapchain_out_of_date = false
		}

		if !draw_frame(repro) {
			return false
		}
	}
	return true
}

swapchain_extent_requires_recreation :: proc(repro: ^Repro, width, height: u32) -> bool {
	if repro.swapchain.handle == {} || !case_uses_oversized_extent(repro.scenario) {
		return true
	}
	return width > repro.swapchain.extent.width || height > repro.swapchain.extent.height
}

framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: c.int) {
	_ = width
	_ = height
	repro := cast(^Repro)glfw.GetWindowUserPointer(window)
	if repro != nil {
		repro.resize_pending = true
	}
}

initialize_vulkan :: proc(repro: ^Repro) -> bool {
	loader := glfw.GetInstanceProcAddress(nil, "vkGetInstanceProcAddr")
	if loader == nil {
		fmt.eprintln("Vulkan loader unavailable")
		return false
	}
	vk.load_proc_addresses_global(loader)

	if result := create_instance(repro); result != .SUCCESS {
		log_vulkan_failure("vkCreateInstance", result)
		return false
	}
	vk.load_proc_addresses_instance(repro.instance)

	if result := create_debug_messenger(repro); result != .SUCCESS {
		log_vulkan_failure("vkCreateDebugUtilsMessengerEXT", result)
		return false
	}

	if result := glfw.CreateWindowSurface(repro.instance, repro.window, nil, &repro.surface); result != .SUCCESS {
		log_vulkan_failure("glfwCreateWindowSurface", result)
		return false
	}

	device, queues, found := select_physical_device(repro.instance, repro.surface, repro.scenario)
	if !found {
		fmt.eprintf(
			"No suitable Vulkan 1.3 GPU supports the %s case requirements\n",
			repro_case_name(repro.scenario),
		)
		return false
	}
	repro.physical_device = device
	repro.queues = queues
	log_physical_device(device)

	if result := create_device(repro); result != .SUCCESS {
		log_vulkan_failure("vkCreateDevice", result)
		return false
	}
	vk.load_proc_addresses_device(repro.device)
	vk.GetDeviceQueue(repro.device, repro.queues.graphics, 0, &repro.graphics_queue)
	vk.GetDeviceQueue(repro.device, repro.queues.present, 0, &repro.present_queue)

	if result := create_frame_resources(repro); result != .SUCCESS {
		log_vulkan_failure("create_frame_resources", result)
		return false
	}
	return true
}

shutdown_vulkan :: proc(repro: ^Repro) {
	if repro.device != nil {
		_ = vk.DeviceWaitIdle(repro.device)
		_ = wait_for_pending_present_fences(repro, &repro.swapchain)
	}

	destroy_swapchain(repro, &repro.swapchain)
	if repro.frame_complete != {} {
		vk.DestroyFence(repro.device, repro.frame_complete, nil)
	}
	if repro.image_acquired != {} {
		vk.DestroySemaphore(repro.device, repro.image_acquired, nil)
	}
	if repro.command_pool != {} {
		vk.DestroyCommandPool(repro.device, repro.command_pool, nil)
	}
	if repro.device != nil {
		vk.DestroyDevice(repro.device, nil)
	}
	if repro.surface != {} {
		vk.DestroySurfaceKHR(repro.instance, repro.surface, nil)
	}
	if repro.debug_messenger != {} {
		vk.DestroyDebugUtilsMessengerEXT(repro.instance, repro.debug_messenger, nil)
	}
	if repro.instance != nil {
		vk.DestroyInstance(repro.instance, nil)
	}

	repro.instance = nil
	repro.device = nil
	repro.surface = {}
}

create_instance :: proc(repro: ^Repro) -> vk.Result {
	required_extensions := glfw.GetRequiredInstanceExtensions()
	extensions: [16]cstring
	required_extra_extensions := 2
	if case_uses_scaling(repro.scenario) {
		required_extra_extensions += 2
	}
	if len(required_extensions) + required_extra_extensions > len(extensions) {
		return .ERROR_EXTENSION_NOT_PRESENT
	}
	extension_count := copy(extensions[:], required_extensions)
	if case_uses_scaling(repro.scenario) {
		if !instance_extension_available(vk.KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME) {
			fmt.eprintln("Scaling case unsupported: VK_KHR_get_surface_capabilities2 unavailable")
			return .ERROR_EXTENSION_NOT_PRESENT
		}
		surface_maintenance_extension, found := select_surface_maintenance_extension()
		if !found {
			fmt.eprintln("Scaling case unsupported: surface maintenance extension unavailable")
			return .ERROR_EXTENSION_NOT_PRESENT
		}
		repro.surface_maintenance_extension = surface_maintenance_extension
		extensions[extension_count] = vk.KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME
		extension_count += 1
		extensions[extension_count] = surface_maintenance_extension
		extension_count += 1
	}
	extensions[extension_count] = vk.EXT_DEBUG_UTILS_EXTENSION_NAME
	extension_count += 1
	extensions[extension_count] = vk.EXT_VALIDATION_FEATURES_EXTENSION_NAME
	extension_count += 1

	layer := cstring("VK_LAYER_KHRONOS_validation")
	application_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "OBS Capture Reproducer",
		applicationVersion = vk.MAKE_API_VERSION(0, 0, 1, 0),
		pEngineName        = "OBS Capture Reproducer",
		engineVersion      = vk.MAKE_API_VERSION(0, 0, 1, 0),
		apiVersion         = vk.API_VERSION_1_3,
	}
	validation_feature := vk.ValidationFeatureEnableEXT.SYNCHRONIZATION_VALIDATION
	validation_features := vk.ValidationFeaturesEXT {
		sType                         = .VALIDATION_FEATURES_EXT,
		enabledValidationFeatureCount = 1,
		pEnabledValidationFeatures    = &validation_feature,
	}
	create_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pNext                   = &validation_features,
		pApplicationInfo        = &application_info,
		enabledLayerCount       = 1,
		ppEnabledLayerNames     = &layer,
		enabledExtensionCount   = u32(extension_count),
		ppEnabledExtensionNames = raw_data(extensions[:extension_count]),
	}
	return vk.CreateInstance(&create_info, nil, &repro.instance)
}

instance_extension_available :: proc(expected: string) -> bool {
	extension_count: u32
	if vk.EnumerateInstanceExtensionProperties(nil, &extension_count, nil) != .SUCCESS ||
	   extension_count > MAX_INSTANCE_EXTENSIONS {
		return false
	}
	extensions: [MAX_INSTANCE_EXTENSIONS]vk.ExtensionProperties
	if vk.EnumerateInstanceExtensionProperties(nil, &extension_count, raw_data(extensions[:])) != .SUCCESS {
		return false
	}
	return extension_properties_contain(extensions[:extension_count], expected)
}

select_surface_maintenance_extension :: proc() -> (cstring, bool) {
	if instance_extension_available(vk.EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME) {
		return vk.EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME, true
	}
	if instance_extension_available(vk.KHR_SURFACE_MAINTENANCE_1_EXTENSION_NAME) {
		return vk.KHR_SURFACE_MAINTENANCE_1_EXTENSION_NAME, true
	}
	return nil, false
}

create_debug_messenger :: proc(repro: ^Repro) -> vk.Result {
	create_info := vk.DebugUtilsMessengerCreateInfoEXT {
		sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.WARNING, .ERROR},
		messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = debug_message_callback,
	}
	return vk.CreateDebugUtilsMessengerEXT(repro.instance, &create_info, nil, &repro.debug_messenger)
}

debug_message_callback :: proc "system" (
	severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	message_types: vk.DebugUtilsMessageTypeFlagsEXT,
	callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) -> b32 {
	context = runtime.default_context()
	_ = severity
	_ = message_types
	_ = user_data
	fmt.eprintf("Vulkan validation: %s\n", callback_data.pMessage)
	return false
}

select_physical_device :: proc(
	instance: vk.Instance,
	surface: vk.SurfaceKHR,
	repro_case: Repro_Case,
) -> (
	vk.PhysicalDevice,
	Queue_Families,
	bool,
) {
	device_count: u32
	if vk.EnumeratePhysicalDevices(instance, &device_count, nil) != .SUCCESS ||
	   device_count == 0 ||
	   device_count > MAX_PHYSICAL_DEVICES {
		return {}, {}, false
	}
	devices: [MAX_PHYSICAL_DEVICES]vk.PhysicalDevice
	if vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(devices[:])) != .SUCCESS {
		return {}, {}, false
	}

	best_device: vk.PhysicalDevice
	best_queues: Queue_Families
	best_score := -1
	for device in devices[:device_count] {
		properties: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(device, &properties)
		device_name := cast(cstring)&properties.deviceName[0]
		fmt.printf(
			"Vulkan candidate: name=%s, PCI ID=%04x:%04x, type=%v, API=%d.%d.%d\n",
			device_name,
			properties.vendorID,
			properties.deviceID,
			properties.deviceType,
			vk.API_VERSION_MAJOR(properties.apiVersion),
			vk.API_VERSION_MINOR(properties.apiVersion),
			vk.API_VERSION_PATCH(properties.apiVersion),
		)
		if properties.apiVersion < vk.API_VERSION_1_3 {
			fmt.printf("Vulkan candidate rejected: name=%s, reason=Vulkan 1.3 unavailable\n", device_name)
			continue
		}
		if !device_supports_case(device, device_name, repro_case) {
			continue
		}
		queues, found := find_queue_families(device, surface)
		if !found {
			fmt.printf("Vulkan candidate rejected: name=%s, reason=graphics/present queues unavailable\n", device_name)
			continue
		}
		score := 10
		if properties.deviceType == .DISCRETE_GPU {
			score += 100
		}
		if queues.graphics == queues.present {
			score += 10
		}
		if score > best_score {
			best_device = device
			best_queues = queues
			best_score = score
		}
	}
	return best_device, best_queues, best_score >= 0
}

device_supports_case :: proc(
	device: vk.PhysicalDevice,
	device_name: cstring,
	repro_case: Repro_Case,
) -> bool {
	extension_count: u32
	result := vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, nil)
	if result != .SUCCESS {
		fmt.printf("Vulkan candidate rejected: name=%s, reason=extension query failed (%v)\n", device_name, result)
		return false
	}
	if extension_count > MAX_DEVICE_EXTENSIONS {
		fmt.printf(
			"Vulkan candidate rejected: name=%s, reason=extension count %d exceeds reproducer limit %d\n",
			device_name,
			extension_count,
			MAX_DEVICE_EXTENSIONS,
		)
		return false
	}
	extensions: [MAX_DEVICE_EXTENSIONS]vk.ExtensionProperties
	result = vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, raw_data(extensions[:]))
	if result != .SUCCESS {
		fmt.printf("Vulkan candidate rejected: name=%s, reason=extension enumeration failed (%v)\n", device_name, result)
		return false
	}
	available := extensions[:extension_count]
	if !extension_properties_contain(available, vk.KHR_SWAPCHAIN_EXTENSION_NAME) {
		fmt.printf("Vulkan candidate rejected: name=%s, reason=VK_KHR_swapchain unavailable\n", device_name)
		return false
	}
	if case_uses_scaling(repro_case) {
		_, extension_found := select_swapchain_maintenance_extension(available)
		if !extension_found {
			fmt.printf(
				"Vulkan candidate rejected: name=%s, reason=swapchain maintenance extension unavailable\n",
				device_name,
			)
			return false
		}
		if !device_supports_swapchain_maintenance(device) {
			fmt.printf(
				"Vulkan candidate rejected: name=%s, reason=swapchainMaintenance1 feature unavailable\n",
				device_name,
			)
			return false
		}
	}
	return true
}

extension_properties_contain :: proc(extensions: []vk.ExtensionProperties, expected: string) -> bool {
	for &extension in extensions {
		if fixed_cstring_equals(extension.extensionName[:], expected) {
			return true
		}
	}
	return false
}

select_swapchain_maintenance_extension :: proc(
	extensions: []vk.ExtensionProperties,
) -> (cstring, bool) {
	if extension_properties_contain(extensions, vk.EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME) {
		return vk.EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME, true
	}
	if extension_properties_contain(extensions, vk.KHR_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME) {
		return vk.KHR_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME, true
	}
	return nil, false
}

device_supports_swapchain_maintenance :: proc(device: vk.PhysicalDevice) -> bool {
	maintenance_features := vk.PhysicalDeviceSwapchainMaintenance1FeaturesKHR {
		sType = .PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_KHR,
	}
	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &maintenance_features,
	}
	vk.GetPhysicalDeviceFeatures2(device, &features)
	return bool(maintenance_features.swapchainMaintenance1)
}

fixed_cstring_equals :: proc(buffer: []byte, expected: string) -> bool {
	if len(expected) >= len(buffer) {
		return false
	}
	for index in 0 ..< len(expected) {
		if buffer[index] != expected[index] {
			return false
		}
	}
	return buffer[len(expected)] == 0
}

find_queue_families :: proc(device: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> (Queue_Families, bool) {
	property_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &property_count, nil)
	if property_count == 0 || property_count > 64 {
		return {}, false
	}
	properties: [64]vk.QueueFamilyProperties
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &property_count, raw_data(properties[:]))

	graphics := INVALID_QUEUE_FAMILY
	present := INVALID_QUEUE_FAMILY
	for property, index in properties[:property_count] {
		if property.queueCount == 0 {
			continue
		}
		present_supported: b32
		if vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(index), surface, &present_supported) != .SUCCESS {
			continue
		}
		if .GRAPHICS in property.queueFlags && bool(present_supported) {
			return {graphics = u32(index), present = u32(index)}, true
		}
		if .GRAPHICS in property.queueFlags && graphics == INVALID_QUEUE_FAMILY {
			graphics = u32(index)
		}
		if bool(present_supported) && present == INVALID_QUEUE_FAMILY {
			present = u32(index)
		}
	}
	return {graphics = graphics, present = present},
		graphics != INVALID_QUEUE_FAMILY && present != INVALID_QUEUE_FAMILY
}

log_physical_device :: proc(device: vk.PhysicalDevice) {
	id_properties := vk.PhysicalDeviceIDProperties {
		sType = .PHYSICAL_DEVICE_ID_PROPERTIES,
	}
	driver_properties := vk.PhysicalDeviceDriverProperties {
		sType = .PHYSICAL_DEVICE_DRIVER_PROPERTIES,
		pNext = &id_properties,
	}
	properties := vk.PhysicalDeviceProperties2 {
		sType = .PHYSICAL_DEVICE_PROPERTIES_2,
		pNext = &driver_properties,
	}
	vk.GetPhysicalDeviceProperties2(device, &properties)

	p := &properties.properties
	fmt.printf(
		"Selected Vulkan adapter: name=%s, PCI ID=%04x:%04x, API=%d.%d.%d, driver=%s (%s)\n",
		cast(cstring)&p.deviceName[0],
		p.vendorID,
		p.deviceID,
		vk.API_VERSION_MAJOR(p.apiVersion),
		vk.API_VERSION_MINOR(p.apiVersion),
		vk.API_VERSION_PATCH(p.apiVersion),
		cast(cstring)&driver_properties.driverName[0],
		cast(cstring)&driver_properties.driverInfo[0],
	)
	if bool(id_properties.deviceLUIDValid) {
		luid := id_properties.deviceLUID
		low := u32(luid[0]) | u32(luid[1]) << 8 | u32(luid[2]) << 16 | u32(luid[3]) << 24
		high := u32(luid[4]) | u32(luid[5]) << 8 | u32(luid[6]) << 16 | u32(luid[7]) << 24
		fmt.printf(
			"Selected Vulkan adapter LUID: %08x:%08x, node_mask=0x%08x\n",
			high,
			low,
			id_properties.deviceNodeMask,
		)
	}
}

create_device :: proc(repro: ^Repro) -> vk.Result {
	priority: f32 = 1
	queue_infos: [2]vk.DeviceQueueCreateInfo
	queue_info_count := 1
	queue_infos[0] = {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = repro.queues.graphics,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}
	if repro.queues.present != repro.queues.graphics {
		queue_infos[1] = {
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = repro.queues.present,
			queueCount       = 1,
			pQueuePriorities = &priority,
		}
		queue_info_count = 2
	}
	extensions: [2]cstring
	extensions[0] = vk.KHR_SWAPCHAIN_EXTENSION_NAME
	extension_count := 1
	maintenance_features := vk.PhysicalDeviceSwapchainMaintenance1FeaturesKHR {
		sType                 = .PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_KHR,
		swapchainMaintenance1 = true,
	}
	feature_chain: rawptr
	if case_uses_scaling(repro.scenario) {
		maintenance_extension, found := select_swapchain_maintenance_extension_for_device(
			repro.physical_device,
		)
		if !found {
			return .ERROR_EXTENSION_NOT_PRESENT
		}
		repro.swapchain_maintenance_extension = maintenance_extension
		extensions[extension_count] = maintenance_extension
		extension_count += 1
		feature_chain = &maintenance_features
	}
	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = feature_chain,
		queueCreateInfoCount    = u32(queue_info_count),
		pQueueCreateInfos       = raw_data(queue_infos[:queue_info_count]),
		enabledExtensionCount   = u32(extension_count),
		ppEnabledExtensionNames = raw_data(extensions[:extension_count]),
	}
	return vk.CreateDevice(repro.physical_device, &create_info, nil, &repro.device)
}

select_swapchain_maintenance_extension_for_device :: proc(
	device: vk.PhysicalDevice,
) -> (cstring, bool) {
	extension_count: u32
	if vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, nil) != .SUCCESS ||
	   extension_count > MAX_DEVICE_EXTENSIONS {
		return nil, false
	}
	extensions: [MAX_DEVICE_EXTENSIONS]vk.ExtensionProperties
	if vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, raw_data(extensions[:])) != .SUCCESS {
		return nil, false
	}
	return select_swapchain_maintenance_extension(extensions[:extension_count])
}

create_frame_resources :: proc(repro: ^Repro) -> vk.Result {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = repro.queues.graphics,
	}
	result := vk.CreateCommandPool(repro.device, &pool_info, nil, &repro.command_pool)
	if result != .SUCCESS {
		return result
	}
	allocate_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = repro.command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	result = vk.AllocateCommandBuffers(repro.device, &allocate_info, &repro.command_buffer)
	if result != .SUCCESS {
		return result
	}
	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	result = vk.CreateSemaphore(repro.device, &semaphore_info, nil, &repro.image_acquired)
	if result != .SUCCESS {
		return result
	}
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	return vk.CreateFence(repro.device, &fence_info, nil, &repro.frame_complete)
}

recreate_swapchain :: proc(repro: ^Repro) -> vk.Result {
	result := vk.DeviceWaitIdle(repro.device)
	if result != .SUCCESS {
		return result
	}
	result = wait_for_pending_present_fences(repro, &repro.swapchain)
	if result != .SUCCESS {
		return result
	}

	replacement: Swapchain
	result = create_swapchain(repro, repro.swapchain.handle, &replacement)
	if result != .SUCCESS {
		destroy_swapchain(repro, &replacement)
		return result
	}
	replacement.generation = repro.swapchain.generation + 1
	destroy_swapchain(repro, &repro.swapchain)
	repro.swapchain = replacement
	window_width, window_height := glfw.GetFramebufferSize(repro.window)
	fmt.printf(
		"Swapchain generation %d: active_case=%s, format=%v, window=%dx%d, swapchain=%dx%d, images=%d, present=%v, scaling=%s\n",
		repro.swapchain.generation,
		repro_case_name(repro.scenario),
		repro.swapchain.format,
		window_width,
		window_height,
		repro.swapchain.extent.width,
		repro.swapchain.extent.height,
		repro.swapchain.image_count,
		repro.swapchain.present_mode,
		present_scaling_name(repro.swapchain.scaling),
	)
	return .SUCCESS
}

create_swapchain :: proc(repro: ^Repro, old_swapchain: vk.SwapchainKHR, output: ^Swapchain) -> vk.Result {
	present_mode, present_mode_result := select_case_present_mode(repro)
	if present_mode_result != .SUCCESS {
		return present_mode_result
	}

	capabilities: vk.SurfaceCapabilitiesKHR
	scaling_capabilities: vk.SurfacePresentScalingCapabilitiesKHR
	result := vk.Result.SUCCESS
	if case_uses_scaling(repro.scenario) {
		capabilities, scaling_capabilities, result = query_scaling_capabilities(
			repro.physical_device,
			repro.surface,
			present_mode,
		)
	} else {
		result = vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(repro.physical_device, repro.surface, &capabilities)
	}
	if result != .SUCCESS {
		return result
	}
	if case_uses_scaling(repro.scenario) {
		if .ONE_TO_ONE not_in scaling_capabilities.supportedPresentScaling {
			fmt.eprintln("Scaling case unsupported: ONE_TO_ONE presentation scaling unavailable")
			return .ERROR_FEATURE_NOT_PRESENT
		}
		if .MIN not_in scaling_capabilities.supportedPresentGravityX ||
		   .MIN not_in scaling_capabilities.supportedPresentGravityY {
			fmt.eprintln("Scaling case unsupported: MIN presentation gravity unavailable")
			return .ERROR_FEATURE_NOT_PRESENT
		}
	}

	format_count: u32
	result = vk.GetPhysicalDeviceSurfaceFormatsKHR(repro.physical_device, repro.surface, &format_count, nil)
	if result != .SUCCESS || format_count == 0 || format_count > MAX_SURFACE_FORMATS {
		return result != .SUCCESS ? result : .ERROR_FORMAT_NOT_SUPPORTED
	}
	formats: [MAX_SURFACE_FORMATS]vk.SurfaceFormatKHR
	result = vk.GetPhysicalDeviceSurfaceFormatsKHR(
		repro.physical_device,
		repro.surface,
		&format_count,
		raw_data(formats[:]),
	)
	if result != .SUCCESS {
		return result
	}
	surface_format, found := select_surface_format(formats[:format_count], case_surface_format(repro.scenario))
	if !found {
		fmt.eprintf("Case unsupported: requested surface format %v with SRGB_NONLINEAR unavailable\n", case_surface_format(repro.scenario))
		return .ERROR_FORMAT_NOT_SUPPORTED
	}
	if .TRANSFER_DST not_in capabilities.supportedUsageFlags {
		return .ERROR_FORMAT_NOT_SUPPORTED
	}

	extent := capabilities.currentExtent
	if extent.width == max(u32) {
		width, height := glfw.GetFramebufferSize(repro.window)
		extent.width = clamp(u32(width), capabilities.minImageExtent.width, capabilities.maxImageExtent.width)
		extent.height = clamp(u32(height), capabilities.minImageExtent.height, capabilities.maxImageExtent.height)
	}
	if case_uses_oversized_extent(repro.scenario) {
		width, height := glfw.GetFramebufferSize(repro.window)
		extent = select_oversized_extent(
			vk.Extent2D{u32(width), u32(height)},
			repro.swapchain.extent,
			scaling_capabilities.minScaledImageExtent,
			scaling_capabilities.maxScaledImageExtent,
		)
	}
	if case_uses_scaling(repro.scenario) &&
	   (extent.width < scaling_capabilities.minScaledImageExtent.width ||
	    extent.height < scaling_capabilities.minScaledImageExtent.height ||
	    extent.width > scaling_capabilities.maxScaledImageExtent.width ||
	    extent.height > scaling_capabilities.maxScaledImageExtent.height) {
		fmt.eprintln("Scaling case unsupported: exact window extent is outside the scalable extent range")
		return .ERROR_INITIALIZATION_FAILED
	}
	image_count := capabilities.minImageCount + 1
	if capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount {
		image_count = capabilities.maxImageCount
	}

	queue_indices := [2]u32{repro.queues.graphics, repro.queues.present}
	sharing_mode := vk.SharingMode.EXCLUSIVE
	queue_index_count: u32
	queue_index_data: [^]u32
	if repro.queues.graphics != repro.queues.present {
		sharing_mode = .CONCURRENT
		queue_index_count = 2
		queue_index_data = raw_data(queue_indices[:])
	}
	composite_alpha, alpha_found := select_composite_alpha(capabilities.supportedCompositeAlpha)
	if !alpha_found {
		return .ERROR_INITIALIZATION_FAILED
	}

	scaling_info := vk.SwapchainPresentScalingCreateInfoKHR {
		sType           = .SWAPCHAIN_PRESENT_SCALING_CREATE_INFO_KHR,
		scalingBehavior = {.ONE_TO_ONE},
		presentGravityX = {.MIN},
		presentGravityY = {.MIN},
	}
	swapchain_chain: rawptr
	if case_uses_scaling(repro.scenario) {
		swapchain_chain = &scaling_info
	}
	create_info := vk.SwapchainCreateInfoKHR {
		sType                 = .SWAPCHAIN_CREATE_INFO_KHR,
		pNext                 = swapchain_chain,
		surface               = repro.surface,
		minImageCount         = image_count,
		imageFormat           = surface_format.format,
		imageColorSpace       = surface_format.colorSpace,
		imageExtent           = extent,
		imageArrayLayers      = 1,
		imageUsage            = {.TRANSFER_DST},
		imageSharingMode      = sharing_mode,
		queueFamilyIndexCount = queue_index_count,
		pQueueFamilyIndices   = queue_index_data,
		preTransform          = capabilities.currentTransform,
		compositeAlpha        = composite_alpha,
		presentMode           = present_mode,
		clipped               = !case_uses_oversized_extent(repro.scenario),
		oldSwapchain          = old_swapchain,
	}
	result = vk.CreateSwapchainKHR(repro.device, &create_info, nil, &output.handle)
	if result != .SUCCESS {
		return result
	}
	output.format = surface_format.format
	output.extent = extent
	output.present_mode = present_mode
	if case_uses_scaling(repro.scenario) {
		output.scaling = {.ONE_TO_ONE}
	}

	result = vk.GetSwapchainImagesKHR(repro.device, output.handle, &output.image_count, nil)
	if result != .SUCCESS || output.image_count == 0 || output.image_count > MAX_SWAPCHAIN_IMAGES {
		return result != .SUCCESS ? result : .ERROR_INITIALIZATION_FAILED
	}
	result = vk.GetSwapchainImagesKHR(repro.device, output.handle, &output.image_count, raw_data(output.images[:]))
	if result != .SUCCESS {
		return result
	}
	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	for index in 0 ..< int(output.image_count) {
		result = vk.CreateSemaphore(repro.device, &semaphore_info, nil, &output.present_ready[index])
		if result != .SUCCESS {
			return result
		}
		if case_uses_present_fences(repro.scenario) {
			fence_info := vk.FenceCreateInfo {
				sType = .FENCE_CREATE_INFO,
			}
			result = vk.CreateFence(repro.device, &fence_info, nil, &output.present_complete[index])
			if result != .SUCCESS {
				return result
			}
		}
	}
	return .SUCCESS
}

wait_for_pending_present_fences :: proc(repro: ^Repro, swapchain: ^Swapchain) -> vk.Result {
	if repro.device == nil || !case_uses_present_fences(repro.scenario) {
		return .SUCCESS
	}
	for index in 0 ..< int(swapchain.image_count) {
		if !swapchain.present_complete_pending[index] {
			continue
		}
		result := vk.WaitForFences(
			repro.device,
			1,
			&swapchain.present_complete[index],
			true,
			max(u64),
		)
		if result != .SUCCESS {
			return result
		}
		swapchain.present_complete_pending[index] = false
	}
	return .SUCCESS
}

select_oversized_extent :: proc(
	requested, retained, minimum, maximum: vk.Extent2D,
) -> vk.Extent2D {
	return {
		width  = oversized_dimension(requested.width, retained.width, minimum.width, maximum.width),
		height = oversized_dimension(requested.height, retained.height, minimum.height, maximum.height),
	}
}

oversized_dimension :: proc(requested, retained, minimum, maximum: u32) -> u32 {
	desired := u64(requested) + u64(OVERSIZED_HEADROOM)
	desired = max(desired, u64(retained))
	desired = max(desired, u64(minimum))
	desired = min(desired, u64(maximum))
	return u32(desired)
}

destroy_swapchain :: proc(repro: ^Repro, swapchain: ^Swapchain) {
	if repro.device == nil {
		return
	}
	for index in 0 ..< int(swapchain.image_count) {
		if swapchain.present_ready[index] != {} {
			vk.DestroySemaphore(repro.device, swapchain.present_ready[index], nil)
		}
		if swapchain.present_complete[index] != {} {
			vk.DestroyFence(repro.device, swapchain.present_complete[index], nil)
		}
	}
	if swapchain.handle != {} {
		vk.DestroySwapchainKHR(repro.device, swapchain.handle, nil)
	}
	swapchain^ = {}
}

select_case_present_mode :: proc(repro: ^Repro) -> (vk.PresentModeKHR, vk.Result) {
	requested := vk.PresentModeKHR.FIFO
	if case_uses_mailbox(repro.scenario) {
		requested = .MAILBOX
	}

	mode_count: u32
	result := vk.GetPhysicalDeviceSurfacePresentModesKHR(
		repro.physical_device,
		repro.surface,
		&mode_count,
		nil,
	)
	if result != .SUCCESS {
		return {}, result
	}
	if mode_count == 0 || mode_count > MAX_PRESENT_MODES {
		return {}, .ERROR_INITIALIZATION_FAILED
	}
	modes: [MAX_PRESENT_MODES]vk.PresentModeKHR
	result = vk.GetPhysicalDeviceSurfacePresentModesKHR(
		repro.physical_device,
		repro.surface,
		&mode_count,
		raw_data(modes[:]),
	)
	if result != .SUCCESS {
		return {}, result
	}
	for mode in modes[:mode_count] {
		if mode == requested {
			return requested, .SUCCESS
		}
	}

	fmt.eprintf(
		"Case %s unsupported: requested present mode %v unavailable\n",
		repro_case_name(repro.scenario),
		requested,
	)
	return {}, .ERROR_FEATURE_NOT_PRESENT
}

query_scaling_capabilities :: proc(
	device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	present_mode: vk.PresentModeKHR,
) -> (
	capabilities: vk.SurfaceCapabilitiesKHR,
	scaling: vk.SurfacePresentScalingCapabilitiesKHR,
	result: vk.Result,
) {
	present_mode_info := vk.SurfacePresentModeKHR {
		sType       = .SURFACE_PRESENT_MODE_KHR,
		presentMode = present_mode,
	}
	surface_info := vk.PhysicalDeviceSurfaceInfo2KHR {
		sType   = .PHYSICAL_DEVICE_SURFACE_INFO_2_KHR,
		pNext   = &present_mode_info,
		surface = surface,
	}
	scaling.sType = .SURFACE_PRESENT_SCALING_CAPABILITIES_KHR
	capabilities_2 := vk.SurfaceCapabilities2KHR {
		sType = .SURFACE_CAPABILITIES_2_KHR,
		pNext = &scaling,
	}
	result = vk.GetPhysicalDeviceSurfaceCapabilities2KHR(device, &surface_info, &capabilities_2)
	capabilities = capabilities_2.surfaceCapabilities
	return
}

present_scaling_name :: proc(scaling: vk.PresentScalingFlagsKHR) -> string {
	if .ONE_TO_ONE in scaling {
		return "ONE_TO_ONE"
	}
	return "none"
}

select_surface_format :: proc(formats: []vk.SurfaceFormatKHR, requested: vk.Format) -> (vk.SurfaceFormatKHR, bool) {
	for surface_format in formats {
		if surface_format.format == requested && surface_format.colorSpace == .SRGB_NONLINEAR {
			return surface_format, true
		}
	}
	return {}, false
}

select_composite_alpha :: proc(flags: vk.CompositeAlphaFlagsKHR) -> (vk.CompositeAlphaFlagsKHR, bool) {
	if .OPAQUE in flags {
		return {.OPAQUE}, true
	}
	if .PRE_MULTIPLIED in flags {
		return {.PRE_MULTIPLIED}, true
	}
	if .POST_MULTIPLIED in flags {
		return {.POST_MULTIPLIED}, true
	}
	if .INHERIT in flags {
		return {.INHERIT}, true
	}
	return {}, false
}

draw_frame :: proc(repro: ^Repro) -> bool {
	result := vk.WaitForFences(repro.device, 1, &repro.frame_complete, true, max(u64))
	if result != .SUCCESS {
		log_vulkan_failure("vkWaitForFences", result)
		return false
	}

	image_index: u32
	result = vk.AcquireNextImageKHR(
		repro.device,
		repro.swapchain.handle,
		max(u64),
		repro.image_acquired,
		{},
		&image_index,
	)
	if result == .ERROR_OUT_OF_DATE_KHR {
		repro.resize_pending = true
		repro.swapchain_out_of_date = true
		return true
	}
	acquire_suboptimal := result == .SUBOPTIMAL_KHR
	if result != .SUCCESS && !acquire_suboptimal {
		log_vulkan_failure("vkAcquireNextImageKHR", result)
		return false
	}
	if case_uses_present_fences(repro.scenario) &&
	   repro.swapchain.present_complete_pending[image_index] {
		result = vk.WaitForFences(
			repro.device,
			1,
			&repro.swapchain.present_complete[image_index],
			true,
			max(u64),
		)
		if result != .SUCCESS {
			log_vulkan_failure("vkWaitForFences (presentation completion)", result)
			return false
		}
		result = vk.ResetFences(repro.device, 1, &repro.swapchain.present_complete[image_index])
		if result != .SUCCESS {
			log_vulkan_failure("vkResetFences (presentation completion)", result)
			return false
		}
		repro.swapchain.present_complete_pending[image_index] = false
	}

	result = vk.ResetFences(repro.device, 1, &repro.frame_complete)
	if result != .SUCCESS {
		log_vulkan_failure("vkResetFences", result)
		return false
	}
	result = vk.ResetCommandBuffer(repro.command_buffer, {})
	if result != .SUCCESS {
		log_vulkan_failure("vkResetCommandBuffer", result)
		return false
	}
	result = record_clear(repro, repro.swapchain.images[image_index])
	if result != .SUCCESS {
		log_vulkan_failure("record_clear", result)
		return false
	}

	wait_stage := vk.PipelineStageFlags{.TRANSFER}
	present_ready := repro.swapchain.present_ready[image_index]
	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &repro.image_acquired,
		pWaitDstStageMask    = &wait_stage,
		commandBufferCount   = 1,
		pCommandBuffers      = &repro.command_buffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &present_ready,
	}
	result = vk.QueueSubmit(repro.graphics_queue, 1, &submit_info, repro.frame_complete)
	if result != .SUCCESS {
		log_vulkan_failure("vkQueueSubmit", result)
		return false
	}

	present_complete := repro.swapchain.present_complete[image_index]
	present_fence_info := vk.SwapchainPresentFenceInfoKHR {
		sType          = .SWAPCHAIN_PRESENT_FENCE_INFO_KHR,
		swapchainCount = 1,
		pFences        = &present_complete,
	}
	present_chain: rawptr
	if case_uses_present_fences(repro.scenario) {
		present_chain = &present_fence_info
	}
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		pNext              = present_chain,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &present_ready,
		swapchainCount     = 1,
		pSwapchains        = &repro.swapchain.handle,
		pImageIndices      = &image_index,
	}
	result = vk.QueuePresentKHR(repro.present_queue, &present_info)
	if case_uses_present_fences(repro.scenario) &&
	   (result == .SUCCESS || result == .SUBOPTIMAL_KHR) {
		repro.swapchain.present_complete_pending[image_index] = true
	}
	if result == .ERROR_OUT_OF_DATE_KHR {
		repro.resize_pending = true
		repro.swapchain_out_of_date = true
	} else if result != .SUCCESS {
		if result != .SUBOPTIMAL_KHR {
			log_vulkan_failure("vkQueuePresentKHR", result)
			return false
		}
		repro.resize_pending = true
	} else if acquire_suboptimal {
		repro.resize_pending = true
	}

	return true
}

record_clear :: proc(repro: ^Repro, image: vk.Image) -> vk.Result {
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	result := vk.BeginCommandBuffer(repro.command_buffer, &begin_info)
	if result != .SUCCESS {
		return result
	}
	range := vk.ImageSubresourceRange {
		aspectMask = {.COLOR},
		levelCount = 1,
		layerCount = 1,
	}
	to_transfer := vk.ImageMemoryBarrier {
		sType               = .IMAGE_MEMORY_BARRIER,
		dstAccessMask       = {.TRANSFER_WRITE},
		oldLayout           = .UNDEFINED,
		newLayout           = .TRANSFER_DST_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image,
		subresourceRange    = range,
	}
	vk.CmdPipelineBarrier(repro.command_buffer, {.TRANSFER}, {.TRANSFER}, {}, 0, nil, 0, nil, 1, &to_transfer)
	clear := vk.ClearColorValue {
		float32 = {0.03, 0.09, 0.16, 1.0},
	}
	vk.CmdClearColorImage(repro.command_buffer, image, .TRANSFER_DST_OPTIMAL, &clear, 1, &range)

	to_present := vk.ImageMemoryBarrier {
		sType               = .IMAGE_MEMORY_BARRIER,
		srcAccessMask       = {.TRANSFER_WRITE},
		oldLayout           = .TRANSFER_DST_OPTIMAL,
		newLayout           = .PRESENT_SRC_KHR,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image,
		subresourceRange    = range,
	}
	vk.CmdPipelineBarrier(repro.command_buffer, {.TRANSFER}, {.BOTTOM_OF_PIPE}, {}, 0, nil, 0, nil, 1, &to_present)
	return vk.EndCommandBuffer(repro.command_buffer)
}

log_vulkan_failure :: proc(operation: string, result: vk.Result) {
	fmt.eprintf("Vulkan reproducer failed during %s: %v\n", operation, result)
}
