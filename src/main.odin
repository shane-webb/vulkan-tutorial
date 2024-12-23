package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:time"
import SDL "vendor:sdl2"
import vk "vendor:vulkan"

WINDOW_WIDTH :: 800
WINDOW_HEIGHT :: 600
MAX_FRAMES_IN_FLIGHT :: 2

GLOBAL_RUNTIME_CONTEXT: runtime.Context
VK_NULL_HANDLE :: 0

AppContext :: struct {
    // hot accesses
    current_frame:              u32, // 4
    frame_buffere_resized:      bool, // 1
    // large and frequently accessed
    uniform_buffers:            []vk.Buffer,
    uniform_buffers_mem:        []vk.DeviceMemory,
    uniform_buffers_mapped:     []rawptr,
    command_buffers:            []vk.CommandBuffer, // 16
    swapchain_framebuffers:     []vk.Framebuffer, // 16
    swapchain_images:           []vk.Image, // 16
    swapchain_image_views:      []vk.ImageView, // 16
    render_finished_semaphores: []vk.Semaphore, // 16
    image_available_semaphores: []vk.Semaphore, // 16
    in_flight_fences:           []vk.Fence, // 16
    descriptor_sets:            []vk.DescriptorSet,
    // all others
    vertex_buffer:              vk.Buffer,
    vertex_buffer_mem:          vk.DeviceMemory,
    index_buffer:               vk.Buffer,
    index_buffer_mem:           vk.DeviceMemory,
    command_pool:               vk.CommandPool,
    descriptor_pool:            vk.DescriptorPool,
    dbg_messenger:              vk.DebugUtilsMessengerEXT,
    instance:                   vk.Instance,
    graphics_queue:             vk.Queue,
    logical_device:             vk.Device,
    phys_device:                vk.PhysicalDevice,
    pipeline:                   vk.Pipeline,
    descriptor_set_layout:      vk.DescriptorSetLayout,
    pipeline_layout:            vk.PipelineLayout,
    present_queue:              vk.Queue, //8
    render_pass:                vk.RenderPass, // 8
    surface:                    vk.SurfaceKHR, // 8
    swapchain:                  vk.SwapchainKHR, // 8
    swapchain_extent:           vk.Extent2D, // 8
    window:                     ^SDL.Window, // 8
    swapchain_image_format:     vk.Format, // 4
}

Vertex :: struct {
    pos:   [2]f32,
    color: [3]f32,
}

UniformBufferObject :: struct {
    model: linalg.Matrix4f32,
    view:  linalg.Matrix4f32,
    proj:  linalg.Matrix4f32,
}

vertices := []Vertex {
    {pos = {-0.5, -0.5}, color = {1.0, 0.0, 0.0}},
    {pos = {0.5, -0.5}, color = {0.0, 1.0, 0.0}},
    {pos = {0.5, 0.5}, color = {0.0, 0.0, 1.0}},
    {pos = {-0.5, 0.5}, color = {1.0, 1.0, 1.0}},
}

indices := []u16{0, 1, 2, 2, 3, 0}

// bundled to simplify querying for the different families at different times
// wrapped with Maybe because 0 is technically a valid queue family value
QueueFamilyIndicies :: struct {
    // Maybe(T), a union that is _either_ T or nil
    // Similar to Option(T) or Result(T) in other languages
    // use '.?' to get the value of a Maybe in a "v, ok" format
    graphics_family: Maybe(u32),
    present_family:  Maybe(u32),
}

SwapchainSupportDetails :: struct {
    capabilities:  vk.SurfaceCapabilitiesKHR,
    formats:       []vk.SurfaceFormatKHR,
    present_modes: []vk.PresentModeKHR,
}


logger: log.Logger
ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, ODIN_DEBUG)
// VK_LAYER_KRONOS_validation comes from the LunarG SDK
// there are other validation layers that can be used
VALIDATION_LAYERS := []cstring{"VK_LAYER_KHRONOS_validation"}
DEVICE_EXTENSIONS := []cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}


// ========================================= MAIN =========================================
main :: proc() {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    defer {
        if len(track.allocation_map) > 0 {
            log.errorf("=== %v allocations not freed: ===\n", len(track.allocation_map))
            for _, entry in track.allocation_map {
                log.errorf("- %v bytes @ %v\n", entry.size, entry.location)
            }
        }
        if len(track.bad_free_array) > 0 {
            log.errorf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
            for entry in track.bad_free_array {
                log.errorf("- %p @ %v\n", entry.memory, entry.location)
            }
        }
        mem.tracking_allocator_destroy(&track)
    }
    // ===============================================================================


    ctx: AppContext
    logger = log.create_console_logger()
    context.logger = logger
    GLOBAL_RUNTIME_CONTEXT = context
    when ENABLE_VALIDATION_LAYERS do log.debug("-- DEBUG MODE --")

    init_window(&ctx)

    init_vulkan(&ctx)

    // print_struct_sizes(&ctx)

    loop: for {     // labeled control flow
        event: SDL.Event
        for SDL.PollEvent(&event) {
            #partial switch event.type {
            case .KEYDOWN:
                #partial switch event.key.keysym.sym {
                case .ESCAPE:
                    break loop
                }
            case .QUIT:
                break loop
            }
        }
        draw_frame(&ctx)
    }
    vk.DeviceWaitIdle(ctx.logical_device)

    cleanup(&ctx)

    log.info("SUCCESS")
    log.destroy_console_logger(logger)
}

// ========================================= VULKAN INSTANCE =========================================
init_vulkan :: proc(ctx: ^AppContext) {
    vk.load_proc_addresses_global(SDL.Vulkan_GetVkGetInstanceProcAddr())
    assert(vk.CreateInstance != nil, "Vulkan function pointers not loaded")

    create_instance(ctx)
    vk.load_proc_addresses_instance(ctx.instance)

    when ENABLE_VALIDATION_LAYERS {
        setup_debug_messenger(ctx)
    }

    create_surface(ctx)
    pick_physical_device(ctx)
    create_logical_device(ctx)
    vk.load_proc_addresses_device(ctx.logical_device)
    create_swap_chain(ctx)
    create_image_views(ctx)
    create_render_pass(ctx)
    create_descriptor_set_layout(ctx)
    create_graphics_pipeline(ctx)
    create_framebuffers(ctx)
    create_command_pool(ctx)
    create_vertex_buffer(ctx)
    create_index_buffer(ctx)
    create_uniform_buffers(ctx)
    create_descriptor_pool(ctx)
    create_descriptor_sets(ctx)
    create_command_buffers(ctx)
    create_sync_objects(ctx)

    free_all(context.temp_allocator)
}

create_instance :: proc(ctx: ^AppContext) {
    app_info := vk.ApplicationInfo {
        sType            = vk.StructureType.APPLICATION_INFO,
        pApplicationName = "Odin VkGuide",
        pEngineName      = "No Engine",
        engineVersion    = vk.MAKE_VERSION(1, 1, 0),
        apiVersion       = vk.API_VERSION_1_1,
    }

    extensions := get_required_extensions(ctx)

    instance_CI := vk.InstanceCreateInfo {
        sType                   = vk.StructureType.INSTANCE_CREATE_INFO,
        pApplicationInfo        = &app_info,
        enabledExtensionCount   = u32(len(extensions)),
        ppEnabledExtensionNames = raw_data(extensions),
        enabledLayerCount       = 0,
    }

    when ENABLE_VALIDATION_LAYERS {
        messenger_CI: vk.DebugUtilsMessengerCreateInfoEXT
        populate_dbg_messenger_CI(&messenger_CI)
        log.debug("Validation layers enabled")
        instance_CI.ppEnabledLayerNames = raw_data(VALIDATION_LAYERS)
        instance_CI.enabledLayerCount = u32(len(VALIDATION_LAYERS))
        instance_CI.pNext = &messenger_CI
    } else {
        instance_CI.enabledLayerCount = 0
        instance_CI.pNext = nil
    }


    // will pretty print a struct
    // log.infof("%#v", instance_CI)
    // how to print the value of a multi pointer
    // log.infof("%#v", instance_CI.ppEnabledExtensionNames[0])

    result := vk.CreateInstance(&instance_CI, nil, &ctx.instance)
    log.assertf(result == .SUCCESS, "CreateInstance failed with result: %d", result)

    instance_extension_count: u32
    vk.EnumerateInstanceExtensionProperties(nil, &instance_extension_count, nil)
    instance_extensions := make([]vk.ExtensionProperties, instance_extension_count, context.temp_allocator)
    vk.EnumerateInstanceExtensionProperties(nil, &instance_extension_count, raw_data(instance_extensions))
    // need "addressable semantics" in this loop in order to cast values from the iterable value
    // pass the iterable value by pointer in order to accomplish that
    // (and use the cstring cast since the strings from Vulkan are cstrings, i.e. null terminated)
    // for &ext in instance_extensions do log.infof("Extension: %s", cstring(&ext.extensionName[0]))
}

check_validation_layer_support :: proc() -> bool {
    layer_count: u32
    vk.EnumerateInstanceLayerProperties(&layer_count, nil)
    layers := make([]vk.LayerProperties, layer_count, context.temp_allocator)

    vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(layers))

    for name in VALIDATION_LAYERS {
        layer_found: bool
        for &layer in layers {
            prop := cstring(&layer.layerName[0])
            // log.infof("Instance Layer Property: %s", prop)
            if name == prop {
                log.debugf("Validation layer %q found", name)
                layer_found = true
                break
            }
        }

        if !layer_found {
            log.errorf("Validation layer %q not available", name)
            return false
        }
    }

    return true
}

get_required_extensions :: proc(ctx: ^AppContext) -> [dynamic]cstring {
    count: u32
    SDL.Vulkan_GetInstanceExtensions(ctx.window, &count, nil)
    extensions := make([dynamic]cstring, count, context.temp_allocator)
    defer delete(extensions)

    SDL.Vulkan_GetInstanceExtensions(ctx.window, &count, raw_data(extensions[:]))

    when ENABLE_VALIDATION_LAYERS {
        if check_validation_layer_support() {
            append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
        }

    }
    return extensions
}


vk_messenger_callback: vk.ProcDebugUtilsMessengerCallbackEXT : proc "system" (
    messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
    messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
    pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
    pUserData: rawptr,
) -> b32 {

    if pCallbackData.pMessage == nil do return false
    // context = (cast(^runtime.Context)pUserData)^
    context = GLOBAL_RUNTIME_CONTEXT
    if .INFO | .VERBOSE in messageSeverity {
        log.info(pCallbackData.pMessage)
    } else if .WARNING in messageSeverity {
        log.warn(pCallbackData.pMessage)
    } else if .ERROR in messageSeverity {
        log.error(pCallbackData.pMessage)
    }
    return false
}


// two separate messenger_create_info structs are required if validating instance creation/destruction is desired
// (and if you're verifying the messenger callback with an instance creation/destruction function,
// you'll need both in order to see the message)
populate_dbg_messenger_CI :: proc(create_info: ^vk.DebugUtilsMessengerCreateInfoEXT) {
    create_info := create_info
    create_info.sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
    create_info.messageSeverity = {.ERROR, .WARNING}
    create_info.messageType = {.GENERAL, .VALIDATION, .PERFORMANCE}
    create_info.pfnUserCallback = vk_messenger_callback
    create_info.pUserData = &GLOBAL_RUNTIME_CONTEXT
}




// odinfmt: disable
setup_debug_messenger :: proc(ctx: ^AppContext) {
    // debug messenger is an extension function so it needs to be loaded separately
    // vk.CreateDebugUtilsMessengerEXT =
    //     auto_cast vk.GetInstanceProcAddr(ctx.instance, "vkCreateDebugUtilsMessengerEXT")
    assert(vk.CreateDebugUtilsMessengerEXT != nil, "Create debug messenger proc address is nil")
    //
    // vk.DestroyDebugUtilsMessengerEXT = 
    //     auto_cast vk.GetInstanceProcAddr(ctx.instance, "vkDestroyDebugUtilsMessengerEXT")
    // assert(vk.DestroyDebugUtilsMessengerEXT != nil, "Destroy debug messenger proc address is nil")

    // severity based on logger level
    // can be used to change the messages for the messenger callback
    // not sure what the difference is between this severity and the one it has now...
    // severity: vk.DebugUtilsMessageSeverityFlagsEXT
    // if context.logger.lowest_level <= .Error {
    //     severity |= {.ERROR}
    // }
    // if context.logger.lowest_level <= .Warning {
    //     severity |= {.WARNING}
    // }
    // if context.logger.lowest_level <= .Info {
    //     severity |= {.INFO}
    // }
    // if context.logger.lowest_level <= .Debug {
    //     severity |= {.VERBOSE}
    // }

    dbg_messenger_CI: vk.DebugUtilsMessengerCreateInfoEXT
    populate_dbg_messenger_CI(&dbg_messenger_CI)

    result := vk.CreateDebugUtilsMessengerEXT(ctx.instance, &dbg_messenger_CI, nil, &ctx.dbg_messenger)
    log.assertf(result == .SUCCESS, "Debug messenger creation failed with result: %v", result)
      //send test debug message
      // msg_callback_data : vk.DebugUtilsMessengerCallbackDataEXT = {
      //   .DEBUG_UTILS_MESSENGER_CALLBACK_DATA_EXT,
      //   nil, {}, nil, 0, "test message", 0, nil, 0, nil, 0, nil,
      // }
      // vk.SubmitDebugUtilsMessageEXT(ctx.instance, {.WARNING}, {.GENERAL}, &msg_callback_data)
} // odinfmt: enable


// ========================================= VULKAN DEVICES =========================================
pick_physical_device :: proc(ctx: ^AppContext) {
    device_count: u32
    vk.EnumeratePhysicalDevices(ctx.instance, &device_count, nil)
    assert(device_count != 0, "Failed to find GPUs with Vulkan support.")

    devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
    vk.EnumeratePhysicalDevices(ctx.instance, &device_count, raw_data(devices))

    // no need for addressable semantics here because d is an opaque handle (not dereferencable)
    for d in devices {
        if is_device_suitable(d, ctx) {
            ctx.phys_device = d
            break
        }
    }

}

is_device_suitable :: proc(device: vk.PhysicalDevice, ctx: ^AppContext) -> b32 {
    // manually querying for device compatibility
    //
    // device_propeties: vk.PhysicalDeviceProperties
    // device_features: vk.PhysicalDeviceFeatures
    // vk.GetPhysicalDeviceProperties(device, &device_propeties)
    // vk.GetPhysicalDeviceFeatures(device, &device_features)
    //
    // return device_propeties.deviceType == .DISCRETE_GPU && device_features.geometryShader

    // use the device that can:
    // - draw graphics
    // - present grapics
    // - supports the required extensions (e.g. swapchain)
    indicies := find_queue_families(device, ctx)
    extensions_supported := check_device_extension_support(device)
    _, has_graphics := indicies.graphics_family.?
    _, has_present := indicies.present_family.?

    swap_chain_adequate: bool
    if extensions_supported {
        swap_chain_support := query_swapchain_support(device, ctx)
        swap_chain_adequate = len(swap_chain_support.formats) != 0 && len(swap_chain_support.present_modes) != 0
    }

    return b32(has_graphics) && b32(has_present) && b32(extensions_supported) && swap_chain_adequate
}

find_queue_families :: proc(device: vk.PhysicalDevice, ctx: ^AppContext) -> QueueFamilyIndicies {
    indicies: QueueFamilyIndicies
    present_support: b32

    count: u32
    vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)
    queue_families := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
    vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(queue_families))


    for fam, i in queue_families {
        if .GRAPHICS in fam.queueFlags {
            indicies.graphics_family = u32(i)
            vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), ctx.surface, &present_support)
            if present_support do indicies.present_family = u32(i)
        }
    }
    return indicies
}

create_logical_device :: proc(ctx: ^AppContext) {
    empty :: struct {}
    indices := find_queue_families(ctx.phys_device, ctx)

    unique_indicies := make(map[u32]empty, context.temp_allocator)
    unique_indicies[indices.graphics_family.?] = {}
    unique_indicies[indices.present_family.?] = {}

    queue_create_infos := make([dynamic]vk.DeviceQueueCreateInfo, context.temp_allocator)
    queue_priority := f32(1.0)

    for fam in unique_indicies {
        append(
            &queue_create_infos,
            vk.DeviceQueueCreateInfo {
                sType = .DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex = fam,
                queueCount = 1,
                pQueuePriorities = &queue_priority,
            },
        )
    }

    // empty for now
    device_features: vk.PhysicalDeviceFeatures

    device_CI := vk.DeviceCreateInfo {
        sType                   = .DEVICE_CREATE_INFO,
        pQueueCreateInfos       = raw_data(queue_create_infos),
        queueCreateInfoCount    = u32(len(queue_create_infos)),
        pEnabledFeatures        = &device_features,
        enabledExtensionCount   = u32(len(DEVICE_EXTENSIONS)),
        ppEnabledExtensionNames = raw_data(DEVICE_EXTENSIONS),
    }

    when ENABLE_VALIDATION_LAYERS {
        // these are actually ignored because there is no longer a distinction
        // between device and instance level validation layers
        // however they are set just to be compatible with older Vulkan implementations
        device_CI.enabledLayerCount = u32(len(VALIDATION_LAYERS))
        device_CI.ppEnabledLayerNames = raw_data(VALIDATION_LAYERS)
    } else {
        device_CI.enabledLayerCount = 0
    }

    result := vk.CreateDevice(ctx.phys_device, &device_CI, nil, &ctx.logical_device)
    log.assertf(result == .SUCCESS, "Failed to create logical device with result: %v", result)

    // using 0 here because only a single queue was created
    vk.GetDeviceQueue(ctx.logical_device, indices.graphics_family.?, 0, &ctx.graphics_queue)
    vk.GetDeviceQueue(ctx.logical_device, indices.present_family.?, 0, &ctx.present_queue)
}

// ========================================= VULKAN SURFACE =========================================
create_surface :: proc(ctx: ^AppContext) {
    result := SDL.Vulkan_CreateSurface(ctx.window, ctx.instance, &ctx.surface)
    log.assertf(result == true, "Failed to create window surface")
}

// ========================================= VULKAN SWAPCHAIN =========================================
check_device_extension_support :: proc(device: vk.PhysicalDevice) -> bool {
    count: u32
    vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil)
    available_extensions := make([]vk.ExtensionProperties, count, context.temp_allocator)
    vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(available_extensions))

    required_extensions := make(map[cstring][^]u8, context.temp_allocator)
    for ext in DEVICE_EXTENSIONS {
        required_extensions[ext] = cast([^]u8)ext
    }

    for &ext in available_extensions {
        d := raw_data(&ext.extensionName)
        delete_key(&required_extensions, cstring(d))
    }

    return len(required_extensions) == 0
}

query_swapchain_support :: proc(device: vk.PhysicalDevice, ctx: ^AppContext) -> SwapchainSupportDetails {
    details: SwapchainSupportDetails

    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, ctx.surface, &details.capabilities)

    format_count: u32
    vk.GetPhysicalDeviceSurfaceFormatsKHR(device, ctx.surface, &format_count, nil)
    if format_count != 0 {
        details.formats = make([]vk.SurfaceFormatKHR, format_count, context.temp_allocator)
        vk.GetPhysicalDeviceSurfaceFormatsKHR(device, ctx.surface, &format_count, raw_data(details.formats))
    }

    present_count: u32
    vk.GetPhysicalDeviceSurfacePresentModesKHR(device, ctx.surface, &present_count, nil)
    if present_count != 0 {
        details.present_modes = make([]vk.PresentModeKHR, present_count, context.temp_allocator)
        vk.GetPhysicalDeviceSurfacePresentModesKHR(
            device,
            ctx.surface,
            &present_count,
            raw_data(details.present_modes),
        )
    }

    return details
}

choose_swap_surface_format :: proc(available_formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
    for av_f in available_formats {
        if av_f.format == .B8G8R8A8_SRGB && av_f.colorSpace == .SRGB_NONLINEAR {
            return av_f
        }
    }
    return available_formats[0]
}

choose_swap_present_mode :: proc(available_present_modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {

    for av_p in available_present_modes {
        if av_p == .MAILBOX {
            return av_p
        }
    }
    return vk.PresentModeKHR.FIFO
}

choose_swap_extent :: proc(capabilities: vk.SurfaceCapabilitiesKHR, ctx: ^AppContext) -> vk.Extent2D {
    // swap extent is the resolution of the swap chain images
    // is usually exactly equal to the resolution of the window that is being drawn to, in pixels

    // there's some pixels->coordinates conversion and clamping happening here that should probably be understood
    // will probably be necessary for when dealing with other display sizes/resolutions

    if capabilities.currentExtent.width != max(u32) {
        return capabilities.currentExtent
    } else {
        width, height: i32
        SDL.Vulkan_GetDrawableSize(ctx.window, &width, &height)
        actual_extent := vk.Extent2D {
            width  = u32(width),
            height = u32(height),
        }
        actual_extent.width = clamp(
            actual_extent.width,
            capabilities.minImageExtent.width,
            capabilities.maxImageExtent.width,
        )
        actual_extent.height = clamp(
            actual_extent.height,
            capabilities.minImageExtent.height,
            capabilities.maxImageExtent.height,
        )
        return actual_extent
    }
}

create_swap_chain :: proc(ctx: ^AppContext) {
    swap_chain_support := query_swapchain_support(ctx.phys_device, ctx)
    surface_format := choose_swap_surface_format(swap_chain_support.formats)
    present_mode := choose_swap_present_mode(swap_chain_support.present_modes)
    extent := choose_swap_extent(swap_chain_support.capabilities, ctx)
    indicies := find_queue_families(ctx.phys_device, ctx)
    queue_family_indicies := []u32{indicies.graphics_family.?, indicies.present_family.?}

    image_count := swap_chain_support.capabilities.minImageCount + 1
    if swap_chain_support.capabilities.maxImageCount > 0 &&
       image_count > swap_chain_support.capabilities.maxImageCount {
        image_count = swap_chain_support.capabilities.maxImageCount
    }

    swap_chain_CI := vk.SwapchainCreateInfoKHR {
        sType            = .SWAPCHAIN_CREATE_INFO_KHR,
        surface          = ctx.surface,
        minImageCount    = image_count,
        imageFormat      = surface_format.format,
        imageColorSpace  = surface_format.colorSpace,
        imageExtent      = extent,
        imageArrayLayers = 1,
        imageUsage       = {.COLOR_ATTACHMENT}, // post-processing operations would require a different usage bit. Should probably look into that
    }

    if indicies.graphics_family != indicies.present_family {
        swap_chain_CI.imageSharingMode = .CONCURRENT
        swap_chain_CI.queueFamilyIndexCount = 2
        swap_chain_CI.pQueueFamilyIndices = raw_data(queue_family_indicies)
    } else {
        swap_chain_CI.imageSharingMode = .EXCLUSIVE
        swap_chain_CI.queueFamilyIndexCount = 0
        swap_chain_CI.pQueueFamilyIndices = nil
    }
    swap_chain_CI.preTransform = swap_chain_support.capabilities.currentTransform
    swap_chain_CI.compositeAlpha = {.OPAQUE}
    swap_chain_CI.presentMode = present_mode
    swap_chain_CI.clipped = true
    swap_chain_CI.oldSwapchain = VK_NULL_HANDLE

    result := vk.CreateSwapchainKHR(ctx.logical_device, &swap_chain_CI, nil, &ctx.swapchain)
    log.assertf(result == .SUCCESS, "Failed to create swapchain with result: %v", result)

    swp_image_count: u32
    vk.GetSwapchainImagesKHR(ctx.logical_device, ctx.swapchain, &swp_image_count, nil)
    ctx.swapchain_images = make([]vk.Image, image_count)
    vk.GetSwapchainImagesKHR(ctx.logical_device, ctx.swapchain, &swp_image_count, raw_data(ctx.swapchain_images))

    ctx.swapchain_extent = extent
    ctx.swapchain_image_format = surface_format.format
}

recreate_swap_chain :: proc(ctx: ^AppContext) {
    vk.DeviceWaitIdle(ctx.logical_device)

    cleanup_swap_chain(ctx)

    create_swap_chain(ctx)
    create_image_views(ctx)
    create_framebuffers(ctx)
}

cleanup_swap_chain :: proc(ctx: ^AppContext) {

    for buf in ctx.swapchain_framebuffers {
        vk.DestroyFramebuffer(ctx.logical_device, buf, nil)
    }

    for img in ctx.swapchain_image_views {
        vk.DestroyImageView(ctx.logical_device, img, nil)
    }
    vk.DestroySwapchainKHR(ctx.logical_device, ctx.swapchain, nil)

    delete(ctx.swapchain_image_views)
    delete(ctx.swapchain_framebuffers)
}

// ========================================= VULKAN IMAGES =========================================
// stuff about mipmapping here, would probably be good to know more about the image views
create_image_views :: proc(ctx: ^AppContext) {
    ctx.swapchain_image_views = make([]vk.ImageView, len(ctx.swapchain_images))

    for img, i in ctx.swapchain_images {
        create_info := vk.ImageViewCreateInfo {
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = img,
            viewType = .D2,
            format = ctx.swapchain_image_format,
            components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
            subresourceRange = {
                aspectMask = {.COLOR},
                baseMipLevel = 0,
                levelCount = 1,
                baseArrayLayer = 0,
                layerCount = 1,
            },
        }
        result := vk.CreateImageView(ctx.logical_device, &create_info, nil, &ctx.swapchain_image_views[i])
        log.assertf(result == .SUCCESS, "Failed to create image views with result: %v", result)
    }
}

// ========================================= VULKAN PIPELINE =========================================
create_render_pass :: proc(ctx: ^AppContext) {
    color_attachment := vk.AttachmentDescription {
        format        = ctx.swapchain_image_format,
        samples       = {._1},
        loadOp        = .CLEAR,
        storeOp       = .STORE,
        initialLayout = .UNDEFINED,
        finalLayout   = .PRESENT_SRC_KHR,
    }

    color_attachment_ref := vk.AttachmentReference {
        attachment = 0,
        layout     = .COLOR_ATTACHMENT_OPTIMAL,
    }

    subpass := vk.SubpassDescription {
        pipelineBindPoint    = .GRAPHICS,
        colorAttachmentCount = 1,
        pColorAttachments    = &color_attachment_ref,
    }

    dependency := vk.SubpassDependency {
        srcSubpass    = vk.SUBPASS_EXTERNAL,
        dstSubpass    = u32(0),
        srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
        // srcAccessMask = {.INDIRECT_COMMAND_READ},
        dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
        dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
    }

    create_info := vk.RenderPassCreateInfo {
        sType           = .RENDER_PASS_CREATE_INFO,
        attachmentCount = 1,
        pAttachments    = &color_attachment,
        subpassCount    = 1,
        pSubpasses      = &subpass,
        dependencyCount = 1,
        pDependencies   = &dependency,
    }
    result := vk.CreateRenderPass(ctx.logical_device, &create_info, nil, &ctx.render_pass)
    log.assertf(result == .SUCCESS, "Failed to create render pass with result: %v", result)
}

create_graphics_pipeline :: proc(ctx: ^AppContext) {
    /*
        Shader stages:      the shader modules that define the functionality of the programmable stages of the graphics pipeline
        Fixed-function      state: all of the structures that define the fixed-function stages of the pipeline, like input assembly, rasterizer, viewport and color blending
        Pipeline layout:    the uniform and push values referenced by the shader that can be updated at draw time
        Render pass:        the attachments referenced by the pipeline stages and their usage
    */

    // Shader modules setup
    // ----------------------------------------------------------------------------
    vert_handle, vert_open_ok := os.open("C:/Users/shane/dev/vulkan_guide/bin/vert.spv")
    defer os.close(vert_handle)
    frag_handle, frag_open_ok := os.open("C:/Users/shane/dev/vulkan_guide/bin/frag.spv")
    defer os.close(frag_handle)
    if vert_open_ok != nil || frag_open_ok != nil {
        log.panicf("Failed to open shader file - frag:%v\tvert:%v", frag_open_ok, vert_open_ok)
    }

    vert_file, vert_read_ok := os.read_entire_file_from_handle(vert_handle)
    defer delete(vert_file)
    frag_file, frag_read_ok := os.read_entire_file_from_handle(frag_handle)
    defer delete(frag_file)
    if vert_read_ok != true || frag_read_ok != true {
        log.panic("Failed to read shader file")
    }

    vert_shader_module := create_shader_module(ctx, vert_file)
    frag_shader_module := create_shader_module(ctx, frag_file)

    vert_shader_stage_info := vk.PipelineShaderStageCreateInfo {
        sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage  = {.VERTEX},
        module = vert_shader_module,
        pName  = "main",
    }
    frag_shader_stage_info := vk.PipelineShaderStageCreateInfo {
        sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage  = {.FRAGMENT},
        module = frag_shader_module,
        pName  = "main",
    }

    shader_stages: []vk.PipelineShaderStageCreateInfo = {vert_shader_stage_info, frag_shader_stage_info}

    // Fixed functions setup
    // ----------------------------------------------------------------------------

    // these two would normally not be filled in like this I think...
    vertex_binding_description := vk.VertexInputBindingDescription {
        binding   = 0,
        stride    = size_of(Vertex),
        inputRate = .VERTEX,
    }
    vertex_attribute_descriptions := [?]vk.VertexInputAttributeDescription {
        {binding = 0, location = 0, format = .R32G32_SFLOAT, offset = cast(u32)offset_of(Vertex, pos)},
        {binding = 0, location = 1, format = .R32G32B32_SFLOAT, offset = cast(u32)offset_of(Vertex, color)},
    }
    // vertext input
    vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
        sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        vertexBindingDescriptionCount   = 1,
        pVertexBindingDescriptions      = &vertex_binding_description,
        vertexAttributeDescriptionCount = len(vertex_attribute_descriptions),
        pVertexAttributeDescriptions    = raw_data(&vertex_attribute_descriptions),
    }

    // input_assembly
    input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
        sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology               = .TRIANGLE_LIST,
        primitiveRestartEnable = b32(false),
    }

    // viewport and scissors
    viewport := vk.Viewport {
        x        = f32(0.0),
        y        = f32(0.0),
        width    = f32(ctx.swapchain_extent.width),
        height   = f32(ctx.swapchain_extent.height),
        minDepth = f32(0.0),
        maxDepth = f32(1.0),
    }

    scissor := vk.Rect2D {
        offset = {0, 0},
        extent = ctx.swapchain_extent,
    }

    // dynamic state
    dynamic_states := []vk.DynamicState{vk.DynamicState.VIEWPORT, vk.DynamicState.SCISSOR}
    dyanmic_state := vk.PipelineDynamicStateCreateInfo {
        sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount = u32(len(dynamic_states)),
        pDynamicStates    = raw_data(dynamic_states),
    }

    // viewport state
    viewport_state := vk.PipelineViewportStateCreateInfo {
        sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        scissorCount  = 1,
        pViewports    = &viewport,
        pScissors     = &scissor,
    }

    // rasterizer
    rasterizer := vk.PipelineRasterizationStateCreateInfo {
        sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        depthClampEnable        = b32(false),
        rasterizerDiscardEnable = b32(false),
        polygonMode             = .FILL,
        lineWidth               = f32(1.0),
        cullMode                = {.BACK},
        frontFace               = .COUNTER_CLOCKWISE,
        depthBiasEnable         = b32(false),
        depthBiasConstantFactor = f32(0.0),
        depthBiasClamp          = f32(0.0),
        depthBiasSlopeFactor    = f32(0.0),
    }

    // multisampling (for anti-aliasing, requires enabling a GPU feature)
    multisampling := vk.PipelineMultisampleStateCreateInfo {
        sType                 = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        sampleShadingEnable   = b32(false),
        rasterizationSamples  = {._1},
        minSampleShading      = f32(1.0),
        pSampleMask           = nil,
        alphaToCoverageEnable = b32(false),
        alphaToOneEnable      = b32(false),
    }

    // depth and stencil testing
    // TBD

    // color blending - setup differs if there is more than one framebuffer
    color_blend_attachment := vk.PipelineColorBlendAttachmentState {
        colorWriteMask      = {.R, .G, .B, .A},
        blendEnable         = b32(false),
        srcColorBlendFactor = .ONE,
        dstColorBlendFactor = .ZERO,
        colorBlendOp        = .ADD,
        srcAlphaBlendFactor = .ONE,
        dstAlphaBlendFactor = .ZERO,
        alphaBlendOp        = .ADD,
    }

    color_blending := vk.PipelineColorBlendStateCreateInfo {
        sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        logicOpEnable   = b32(false),
        logicOp         = .COPY,
        attachmentCount = 1,
        pAttachments    = &color_blend_attachment,
        blendConstants  = {f32(0.0), f32(0.0), f32(0.0), f32(0.0)},
    }

    // pipeline layout
    pipeline_layout_info := vk.PipelineLayoutCreateInfo {
        sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount         = 1,
        pSetLayouts            = &ctx.descriptor_set_layout,
        pushConstantRangeCount = 0,
        pPushConstantRanges    = nil,
    }

    result_pipeline_layout := vk.CreatePipelineLayout(
        ctx.logical_device,
        &pipeline_layout_info,
        nil,
        &ctx.pipeline_layout,
    )
    log.assertf(
        result_pipeline_layout == .SUCCESS,
        "Failed to create pipeline layout with result: %v",
        result_pipeline_layout,
    )

    pipeline_info := vk.GraphicsPipelineCreateInfo {
        sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
        stageCount          = 2,
        pStages             = raw_data(shader_stages),
        pVertexInputState   = &vertex_input_info,
        pInputAssemblyState = &input_assembly,
        pViewportState      = &viewport_state,
        pRasterizationState = &rasterizer,
        pMultisampleState   = &multisampling,
        pDepthStencilState  = nil,
        pColorBlendState    = &color_blending,
        pDynamicState       = &dyanmic_state,
        layout              = ctx.pipeline_layout,
        renderPass          = ctx.render_pass,
        subpass             = 0,
        basePipelineIndex   = -1,
        basePipelineHandle  = VK_NULL_HANDLE,
    }


    result_pipeline := vk.CreateGraphicsPipelines(
        ctx.logical_device,
        VK_NULL_HANDLE,
        1,
        &pipeline_info,
        nil,
        &ctx.pipeline,
    )
    log.assertf(result_pipeline == .SUCCESS, "Failed to create pipeline with result: %v", result_pipeline)

    vk.DestroyShaderModule(ctx.logical_device, frag_shader_module, nil)
    vk.DestroyShaderModule(ctx.logical_device, vert_shader_module, nil)
}

create_shader_module :: proc(ctx: ^AppContext, code: []u8) -> vk.ShaderModule {
    code := code
    create_info := vk.ShaderModuleCreateInfo {
        sType    = .SHADER_MODULE_CREATE_INFO,
        codeSize = len(code),
        pCode    = cast(^u32)raw_data(code),
    }

    shader_module: vk.ShaderModule
    result := vk.CreateShaderModule(ctx.logical_device, &create_info, nil, &shader_module)

    log.assertf(result == .SUCCESS, "Failed to create shader module with result:%v", result)

    return shader_module
}
// ========================================= VULKAN FRAMEBUFFERS =========================================
create_framebuffers :: proc(ctx: ^AppContext) {
    ctx.swapchain_framebuffers = make([]vk.Framebuffer, len(ctx.swapchain_image_views))

    for img, i in ctx.swapchain_image_views {
        attachments := []vk.ImageView{img}

        frame_buffer_info := vk.FramebufferCreateInfo {
            sType           = .FRAMEBUFFER_CREATE_INFO,
            renderPass      = ctx.render_pass,
            attachmentCount = 1,
            pAttachments    = raw_data(attachments),
            width           = ctx.swapchain_extent.width,
            height          = ctx.swapchain_extent.height,
            layers          = 1,
        }

        result := vk.CreateFramebuffer(ctx.logical_device, &frame_buffer_info, nil, &ctx.swapchain_framebuffers[i])
        log.assertf(result == .SUCCESS, "Failed to create framebuffer for index %v with result: %v", i, result)
    }
}
// ========================================= VULKAN COMMANDS =========================================
create_command_pool :: proc(ctx: ^AppContext) {
    queue_family_indicies := find_queue_families(ctx.phys_device, ctx)

    pool_info := vk.CommandPoolCreateInfo {
        sType            = .COMMAND_POOL_CREATE_INFO,
        flags            = {.RESET_COMMAND_BUFFER},
        queueFamilyIndex = queue_family_indicies.graphics_family.?,
    }

    result := vk.CreateCommandPool(ctx.logical_device, &pool_info, nil, &ctx.command_pool)
    log.assertf(result == .SUCCESS, "Failed to create command pool with result: %v", result)
}

create_command_buffers :: proc(ctx: ^AppContext) {
    ctx.command_buffers = make([]vk.CommandBuffer, MAX_FRAMES_IN_FLIGHT)
    alloc_info := vk.CommandBufferAllocateInfo {
        sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool        = ctx.command_pool,
        level              = .PRIMARY,
        commandBufferCount = u32(len(ctx.command_buffers)),
    }

    result := vk.AllocateCommandBuffers(ctx.logical_device, &alloc_info, raw_data(ctx.command_buffers))
    log.assertf(result == .SUCCESS, "Failed to allocate command buffers with result: %v", result)
}

record_command_buffer :: proc(ctx: ^AppContext, cmd_buffer: vk.CommandBuffer, image_index: u32) {
    begin_info := vk.CommandBufferBeginInfo {
        sType            = .COMMAND_BUFFER_BEGIN_INFO,
        // flags            = {.ONE_TIME_SUBMIT},
        pInheritanceInfo = nil,
    }

    result_command_begin := vk.BeginCommandBuffer(cmd_buffer, &begin_info)
    log.assertf(
        result_command_begin == .SUCCESS,
        "Failed to begin recording command buffer with result: %v",
        result_command_begin,
    )

    clear_color := vk.ClearValue {
        color = {float32 = {0.02, 0.1, 0.25, 1.0}},
    }
    render_pass_info := vk.RenderPassBeginInfo {
        sType = .RENDER_PASS_BEGIN_INFO,
        renderPass = ctx.render_pass,
        framebuffer = ctx.swapchain_framebuffers[image_index],
        renderArea = {offset = {0, 0}, extent = ctx.swapchain_extent},
        clearValueCount = 1,
        pClearValues = &clear_color,
    }

    vk.CmdBeginRenderPass(cmd_buffer, &render_pass_info, .INLINE)
    {
        vk.CmdBindPipeline(cmd_buffer, .GRAPHICS, ctx.pipeline)

        viewport := vk.Viewport {
            x        = f32(0.0),
            y        = f32(0.0),
            width    = f32(ctx.swapchain_extent.width),
            height   = f32(ctx.swapchain_extent.height),
            minDepth = f32(0.0),
            maxDepth = f32(1.0),
        }
        vk.CmdSetViewport(cmd_buffer, u32(0), u32(1), &viewport)

        scissor := vk.Rect2D {
            offset = {0, 0},
            extent = ctx.swapchain_extent,
        }
        vk.CmdSetScissor(cmd_buffer, u32(0), u32(1), &scissor)

        vertex_buffers := []vk.Buffer{ctx.vertex_buffer}
        offsets := []vk.DeviceSize{0}
        vk.CmdBindVertexBuffers(cmd_buffer, 0, 1, raw_data(vertex_buffers), raw_data(offsets))

        vk.CmdBindIndexBuffer(cmd_buffer, ctx.index_buffer, 0, .UINT16)

        vk.CmdBindDescriptorSets(
            cmd_buffer,
            .GRAPHICS,
            ctx.pipeline_layout,
            0,
            1,
            &ctx.descriptor_sets[ctx.current_frame],
            0,
            nil,
        )
        vk.CmdDrawIndexed(cmd_buffer, u32(len(indices)), 1, 0, 0, 0)
    }
    vk.CmdEndRenderPass(cmd_buffer)

    result_command_end := vk.EndCommandBuffer(cmd_buffer)
    log.assertf(result_command_end == .SUCCESS, "Failed to end recording commands with result: %v", result_command_end)
}
// ========================================= VULKAN DRAWING =========================================
/*
At a high level, rendering a frame in Vulkan consists of a common set of steps:

    - Wait for the previous frame to finish
    - Acquire an image from the swap chain
    - Record a command buffer which draws the scene onto that image
    - Submit the recorded command buffer
    - Present the swap chain image
*/

create_sync_objects :: proc(ctx: ^AppContext) {
    ctx.image_available_semaphores = make([]vk.Semaphore, MAX_FRAMES_IN_FLIGHT)
    ctx.render_finished_semaphores = make([]vk.Semaphore, MAX_FRAMES_IN_FLIGHT)
    ctx.in_flight_fences = make([]vk.Fence, MAX_FRAMES_IN_FLIGHT)

    semaphore_info := vk.SemaphoreCreateInfo {
        sType = .SEMAPHORE_CREATE_INFO,
    }
    fence_info := vk.FenceCreateInfo {
        sType = .FENCE_CREATE_INFO,
        flags = {.SIGNALED},
    }

    for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
        result_img_semaphore := vk.CreateSemaphore(
            ctx.logical_device,
            &semaphore_info,
            nil,
            &ctx.image_available_semaphores[i],
        )
        result_render_semaphore := vk.CreateSemaphore(
            ctx.logical_device,
            &semaphore_info,
            nil,
            &ctx.render_finished_semaphores[i],
        )
        result_fence := vk.CreateFence(ctx.logical_device, &fence_info, nil, &ctx.in_flight_fences[i])

        log.assertf(
            result_render_semaphore == .SUCCESS && result_img_semaphore == .SUCCESS && result_fence == .SUCCESS,
            "Failed to create a sync obj with result: %v, %v %v",
            result_render_semaphore,
            result_img_semaphore,
            result_fence,
        )
    }


}

draw_frame :: proc(ctx: ^AppContext) {
    vk.WaitForFences(ctx.logical_device, u32(1), &ctx.in_flight_fences[ctx.current_frame], b32(true), max(u64))

    image_index: u32
    result_acquire := vk.AcquireNextImageKHR(
        ctx.logical_device,
        ctx.swapchain,
        max(u64),
        ctx.image_available_semaphores[ctx.current_frame],
        VK_NULL_HANDLE,
        &image_index,
    )
    if result_acquire == .ERROR_OUT_OF_DATE_KHR {
        ctx.frame_buffere_resized = false
        recreate_swap_chain(ctx)
        return
    }
    log.assertf(
        result_acquire == .SUCCESS || result_acquire == .SUBOPTIMAL_KHR,
        "Failed to acquire swapchain image with result: %v",
        result_acquire,
    )

    vk.ResetFences(ctx.logical_device, u32(1), &ctx.in_flight_fences[ctx.current_frame])
    vk.ResetCommandBuffer(ctx.command_buffers[ctx.current_frame], {.RELEASE_RESOURCES})

    record_command_buffer(ctx, ctx.command_buffers[ctx.current_frame], image_index)

    update_uniform_buffer(ctx, ctx.current_frame)

    wait_stages := [?]vk.PipelineStageFlags{{.COLOR_ATTACHMENT_OUTPUT}}
    submit_info := vk.SubmitInfo {
        sType                = .SUBMIT_INFO,
        waitSemaphoreCount   = 1,
        pWaitSemaphores      = &ctx.image_available_semaphores[ctx.current_frame],
        pWaitDstStageMask    = &wait_stages[0],
        commandBufferCount   = 1,
        pCommandBuffers      = &ctx.command_buffers[ctx.current_frame],
        signalSemaphoreCount = 1,
        pSignalSemaphores    = &ctx.render_finished_semaphores[ctx.current_frame],
    }

    result_submit := vk.QueueSubmit(ctx.graphics_queue, 1, &submit_info, ctx.in_flight_fences[ctx.current_frame])
    log.assertf(result_submit == .SUCCESS, "Failed to submit draw command buffer with result: %v", result_submit)

    present_info := vk.PresentInfoKHR {
        sType              = .PRESENT_INFO_KHR,
        swapchainCount     = 1,
        pSwapchains        = &ctx.swapchain,
        pImageIndices      = &image_index,
        pResults           = nil,
        waitSemaphoreCount = 1,
        pWaitSemaphores    = &ctx.render_finished_semaphores[ctx.current_frame],
    }

    vk.QueuePresentKHR(ctx.present_queue, &present_info)
    // log.assertf(
    //     result_present == .SUCCESS,
    //     "Failed to present image with result: %v",
    //     result_present,
    // )

    ctx.current_frame = (ctx.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
}
// ========================================= VULKAN VERTEX BUFFER =========================================
create_vertex_buffer :: proc(ctx: ^AppContext) {
    buffer_size := vk.DeviceSize(size_of(vertices[0]) * len(vertices))

    staging_buffer: vk.Buffer
    staging_buffer_mem: vk.DeviceMemory
    create_buffer(
        ctx,
        buffer_size,
        {.TRANSFER_SRC},
        {.HOST_VISIBLE, .HOST_COHERENT},
        &staging_buffer,
        &staging_buffer_mem,
    )

    data: rawptr
    vk.MapMemory(ctx.logical_device, staging_buffer_mem, 0, buffer_size, {}, &data)
    mem.copy(data, raw_data(vertices), int(buffer_size))
    vk.UnmapMemory(ctx.logical_device, staging_buffer_mem)

    create_buffer(
        ctx,
        buffer_size,
        {.TRANSFER_DST, .VERTEX_BUFFER},
        {.DEVICE_LOCAL},
        &ctx.vertex_buffer,
        &ctx.vertex_buffer_mem,
    )

    copy_buffer(ctx, staging_buffer, ctx.vertex_buffer, buffer_size)

    vk.DestroyBuffer(ctx.logical_device, staging_buffer, nil)
    vk.FreeMemory(ctx.logical_device, staging_buffer_mem, nil)
}

find_memory_type :: proc(ctx: ^AppContext, type_filter: u32, props: vk.MemoryPropertyFlags) -> u32 {
    mem_props: vk.PhysicalDeviceMemoryProperties
    vk.GetPhysicalDeviceMemoryProperties(ctx.phys_device, &mem_props)

    for i in 0 ..< mem_props.memoryTypeCount {
        if (type_filter & (1 << i) != 0) && (mem_props.memoryTypes[i].propertyFlags & props) == props {
            return i
        }
    }
    panic("Failed to find suitable memory type!")
}

create_buffer :: proc(
    ctx: ^AppContext,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    properties: vk.MemoryPropertyFlags,
    buffer: ^vk.Buffer,
    buffer_mem: ^vk.DeviceMemory,
) {
    buffer_mem := buffer_mem

    create_info := vk.BufferCreateInfo {
        sType       = .BUFFER_CREATE_INFO,
        size        = size,
        usage       = usage,
        sharingMode = .EXCLUSIVE,
    }

    result_buffer_create := vk.CreateBuffer(ctx.logical_device, &create_info, nil, buffer)
    log.assertf(result_buffer_create == .SUCCESS, "Failed to create buffer with result: %v", result_buffer_create)

    mem_reqs: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(ctx.logical_device, buffer^, &mem_reqs)

    alloc_info := vk.MemoryAllocateInfo {
        sType           = .MEMORY_ALLOCATE_INFO,
        allocationSize  = mem_reqs.size,
        memoryTypeIndex = find_memory_type(ctx, mem_reqs.memoryTypeBits, properties),
    }

    // NOTE: not a good idea to manually call alloc for every buffer created
    // should instead use a custom allocator (arena style), or use a library
    // like VulkanMemoryAllocator: https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator
    result_memory_alloc := vk.AllocateMemory(ctx.logical_device, &alloc_info, nil, buffer_mem)
    log.assertf(
        result_memory_alloc == .SUCCESS,
        "Failed to allocate buffer memory with result: %v",
        result_memory_alloc,
    )

    vk.BindBufferMemory(ctx.logical_device, buffer^, buffer_mem^, 0)

}

copy_buffer :: proc(ctx: ^AppContext, src_buffer: vk.Buffer, dst_buffer: vk.Buffer, size: vk.DeviceSize) {
    alloc_info := vk.CommandBufferAllocateInfo {
        sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
        level              = .PRIMARY,
        commandPool        = ctx.command_pool,
        commandBufferCount = 1,
    }

    command_buffer: vk.CommandBuffer
    vk.AllocateCommandBuffers(ctx.logical_device, &alloc_info, &command_buffer)

    begin_info := vk.CommandBufferBeginInfo {
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = {.ONE_TIME_SUBMIT},
    }

    vk.BeginCommandBuffer(command_buffer, &begin_info)
    {
        copy_region := vk.BufferCopy {
            srcOffset = 0,
            dstOffset = 0,
            size      = size,
        }

        vk.CmdCopyBuffer(command_buffer, src_buffer, dst_buffer, 1, &copy_region)
    }
    vk.EndCommandBuffer(command_buffer)


    submit_info := vk.SubmitInfo {
        sType              = .SUBMIT_INFO,
        commandBufferCount = 1,
        pCommandBuffers    = &command_buffer,
    }
    vk.QueueSubmit(ctx.graphics_queue, 1, &submit_info, VK_NULL_HANDLE)
    vk.QueueWaitIdle(ctx.graphics_queue)
    vk.FreeCommandBuffers(ctx.logical_device, ctx.command_pool, 1, &command_buffer)
}
// ========================================= VULKAN INDEX BUFFER =========================================
create_index_buffer :: proc(ctx: ^AppContext) {
    buffer_size := vk.DeviceSize(size_of(indices[0]) * len(indices))

    staging_buffer: vk.Buffer
    staging_buffer_mem: vk.DeviceMemory

    create_buffer(
        ctx,
        buffer_size,
        {.TRANSFER_SRC},
        {.HOST_VISIBLE, .HOST_COHERENT},
        &staging_buffer,
        &staging_buffer_mem,
    )

    data: rawptr
    vk.MapMemory(ctx.logical_device, staging_buffer_mem, 0, buffer_size, {}, &data)
    mem.copy(data, raw_data(indices), int(buffer_size))
    vk.UnmapMemory(ctx.logical_device, staging_buffer_mem)

    create_buffer(
        ctx,
        buffer_size,
        {.TRANSFER_DST, .INDEX_BUFFER},
        {.DEVICE_LOCAL},
        &ctx.index_buffer,
        &ctx.index_buffer_mem,
    )

    copy_buffer(ctx, staging_buffer, ctx.index_buffer, buffer_size)

    vk.DestroyBuffer(ctx.logical_device, staging_buffer, nil)
    vk.FreeMemory(ctx.logical_device, staging_buffer_mem, nil)
}
// ========================================= VULKAN UNIFORM BUFFERS =========================================
create_uniform_buffers :: proc(ctx: ^AppContext) {
    buffer_size := vk.DeviceSize(size_of(UniformBufferObject))

    ctx.uniform_buffers = make([]vk.Buffer, MAX_FRAMES_IN_FLIGHT)
    ctx.uniform_buffers_mem = make([]vk.DeviceMemory, MAX_FRAMES_IN_FLIGHT)
    ctx.uniform_buffers_mapped = make([]rawptr, MAX_FRAMES_IN_FLIGHT)

    for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
        create_buffer(
            ctx,
            buffer_size,
            {.UNIFORM_BUFFER},
            {.HOST_VISIBLE, .HOST_COHERENT},
            &ctx.uniform_buffers[i],
            &ctx.uniform_buffers_mem[i],
        )

        // persistent mapping
        vk.MapMemory(
            ctx.logical_device,
            ctx.uniform_buffers_mem[i],
            0,
            buffer_size,
            {},
            &ctx.uniform_buffers_mapped[i],
        )
    }
}

update_uniform_buffer :: proc(ctx: ^AppContext, current_image: u32) {
    start_time := time.tick_now()

    delta := time.tick_lap_time(&start_time)
    radians := f32(90.0) * f32(linalg.PI) / f32(180.0)
    ubo: UniformBufferObject
    ubo.model = linalg.matrix4_rotate_f32((f32(delta) * radians), linalg.Vector3f32{0.0, 0.0, 1.0})

    ubo.view = linalg.matrix4_look_at_f32(
        eye = linalg.Vector3f32{2.0, 2.0, 2.0},
        centre = linalg.Vector3f32{0.0, 0.0, 0.0},
        up = linalg.Vector3f32{0.0, 0.0, 1.0},
    )

    ubo.proj = linalg.matrix4_perspective_f32(
        fovy = f32(45.0),
        aspect = f32(ctx.swapchain_extent.width / ctx.swapchain_extent.height),
        near = f32(0.1),
        far = f32(10.0),
    )

    // flip y axis?
    ubo.proj[1][1] *= -1

    mem.copy(ctx.uniform_buffers_mapped[current_image], &ubo, size_of(ubo))
}
// ========================================= VULKAN DESCRIPTOR SETS =========================================
create_descriptor_set_layout :: proc(ctx: ^AppContext) {
    ubo_layout_binding := vk.DescriptorSetLayoutBinding {
        binding            = 0,
        descriptorType     = .UNIFORM_BUFFER,
        descriptorCount    = 1,
        stageFlags         = {.VERTEX},
        pImmutableSamplers = nil,
    }

    layout_info := vk.DescriptorSetLayoutCreateInfo {
        sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        bindingCount = 1,
        pBindings    = &ubo_layout_binding,
    }

    result := vk.CreateDescriptorSetLayout(ctx.logical_device, &layout_info, nil, &ctx.descriptor_set_layout)
    log.assertf(result == .SUCCESS, "Failed to create descriptor set layout with result: %v", result)


}

create_descriptor_pool :: proc(ctx: ^AppContext) {
    pool_size := vk.DescriptorPoolSize {
        type            = .UNIFORM_BUFFER,
        descriptorCount = u32(MAX_FRAMES_IN_FLIGHT),
    }

    pool_info := vk.DescriptorPoolCreateInfo {
        sType         = .DESCRIPTOR_POOL_CREATE_INFO,
        poolSizeCount = 1,
        pPoolSizes    = &pool_size,
        maxSets       = u32(MAX_FRAMES_IN_FLIGHT),
    }
    result := vk.CreateDescriptorPool(ctx.logical_device, &pool_info, nil, &ctx.descriptor_pool)
    log.assertf(result == .SUCCESS, "Failed to create descriptor pool with result: %v", result)
}

create_descriptor_sets :: proc(ctx: ^AppContext) {
    layouts := make([]vk.DescriptorSetLayout, MAX_FRAMES_IN_FLIGHT)
    defer delete(layouts)
    slice.fill(layouts, ctx.descriptor_set_layout)
    alloc_info := vk.DescriptorSetAllocateInfo {
        sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool     = ctx.descriptor_pool,
        descriptorSetCount = u32(MAX_FRAMES_IN_FLIGHT),
        pSetLayouts        = raw_data(layouts),
    }
    ctx.descriptor_sets = make([]vk.DescriptorSet, MAX_FRAMES_IN_FLIGHT)

    result := vk.AllocateDescriptorSets(ctx.logical_device, &alloc_info, raw_data(ctx.descriptor_sets))
    log.assertf(result == .SUCCESS, "Failed to allocate descriptor sets with result: %v", result)

    for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
        buffer_info := vk.DescriptorBufferInfo {
            buffer = ctx.uniform_buffers[i],
            offset = 0,
            range  = vk.DeviceSize(size_of(UniformBufferObject)),
        }

        descriptor_write := vk.WriteDescriptorSet {
            sType            = .WRITE_DESCRIPTOR_SET,
            dstSet           = ctx.descriptor_sets[i],
            dstBinding       = 0,
            dstArrayElement  = 0,
            descriptorType   = .UNIFORM_BUFFER,
            descriptorCount  = 1,
            pBufferInfo      = &buffer_info,
            pImageInfo       = nil,
            pTexelBufferView = nil,
        }

        vk.UpdateDescriptorSets(ctx.logical_device, 1, &descriptor_write, 0, nil)
    }

}
// ========================================= WINDOW =========================================
init_window :: proc(ctx: ^AppContext) {
    SDL.Init({.VIDEO})
    window := SDL.CreateWindow(
        "Odin Vulkan Again",
        SDL.WINDOWPOS_UNDEFINED,
        SDL.WINDOWPOS_UNDEFINED,
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        {.SHOWN, .VULKAN},
    )
    if window == nil {
        log.error("Failed to create window")
        return
    }
    ctx.window = window

    // TODO: is this all there is to resizing?
    SDL.SetWindowResizable(ctx.window, true)
}

// ========================================= DESTRUCTION =========================================
cleanup :: proc(ctx: ^AppContext) {
    cleanup_swap_chain(ctx)

    vk.DestroyBuffer(ctx.logical_device, ctx.index_buffer, nil)
    vk.FreeMemory(ctx.logical_device, ctx.index_buffer_mem, nil)

    vk.DestroyBuffer(ctx.logical_device, ctx.vertex_buffer, nil)
    vk.FreeMemory(ctx.logical_device, ctx.vertex_buffer_mem, nil)

    vk.DestroyPipeline(ctx.logical_device, ctx.pipeline, nil)
    vk.DestroyPipelineLayout(ctx.logical_device, ctx.pipeline_layout, nil)
    vk.DestroyRenderPass(ctx.logical_device, ctx.render_pass, nil)

    for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
        vk.DestroyBuffer(ctx.logical_device, ctx.uniform_buffers[i], nil)
        vk.FreeMemory(ctx.logical_device, ctx.uniform_buffers_mem[i], nil)
    }

    vk.DestroyDescriptorPool(ctx.logical_device, ctx.descriptor_pool, nil)
    vk.DestroyDescriptorSetLayout(ctx.logical_device, ctx.descriptor_set_layout, nil)

    for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
        vk.DestroySemaphore(ctx.logical_device, ctx.render_finished_semaphores[i], nil)
        vk.DestroySemaphore(ctx.logical_device, ctx.image_available_semaphores[i], nil)
        vk.DestroyFence(ctx.logical_device, ctx.in_flight_fences[i], nil)
    }
    vk.DestroyCommandPool(ctx.logical_device, ctx.command_pool, nil)

    vk.DestroyDevice(ctx.logical_device, nil)

    when ENABLE_VALIDATION_LAYERS {
        vk.DestroyDebugUtilsMessengerEXT(ctx.instance, ctx.dbg_messenger, nil)
    }

    vk.DestroySurfaceKHR(ctx.instance, ctx.surface, nil)
    vk.DestroyInstance(ctx.instance, nil)

    SDL.Vulkan_UnloadLibrary()
    SDL.DestroyWindow(ctx.window)

    delete(ctx.uniform_buffers)
    delete(ctx.uniform_buffers_mapped)
    delete(ctx.uniform_buffers_mem)
    delete(ctx.command_buffers)
    delete(ctx.descriptor_sets)
    delete(ctx.render_finished_semaphores)
    delete(ctx.image_available_semaphores)
    delete(ctx.in_flight_fences)
    delete(ctx.swapchain_images)

    SDL.Quit()
}

print_struct_sizes :: proc(ctx: ^AppContext) {
    id := typeid_of(AppContext)
    count := reflect.struct_field_count(AppContext)
    offset := reflect.struct_field_offsets(id)
    zipped := reflect.struct_fields_zipped(id)

    fmt.println("id: ", id)
    fmt.println("count: ", count)
    fmt.printfln("offsets: %#v", offset)
    fmt.printfln("zipped: %#v", zipped)
}
