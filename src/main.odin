package main

import "base:runtime"
import "core:log"
import "core:mem"
import "core:os"
import SDL "vendor:sdl2"
import vk "vendor:vulkan"

WINDOW_WIDTH :: 1920
WINDOW_HEIGHT :: 1080

GLOBAL_RUNTIME_CONTEXT: runtime.Context
VK_NULL_HANDLE :: 0

AppContext :: struct {
    dbg_messenger:          vk.DebugUtilsMessengerEXT,
    instance:               vk.Instance,
    graphics_queue:         vk.Queue,
    logical_device:         vk.Device,
    phys_device:            vk.PhysicalDevice,
    present_queue:          vk.Queue,
    surface:                vk.SurfaceKHR,
    swapchain:              vk.SwapchainKHR,
    swapchain_extent:       vk.Extent2D,
    swapchain_images:       []vk.Image,
    swapchain_image_format: vk.Format,
    swapchain_image_views:  []vk.ImageView,
    window:                 ^SDL.Window,
}

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
    }

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
    create_graphics_pipeline(ctx)

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
    instance_extensions := make(
        []vk.ExtensionProperties,
        instance_extension_count,
        context.temp_allocator,
    )
    vk.EnumerateInstanceExtensionProperties(
        nil,
        &instance_extension_count,
        raw_data(instance_extensions),
    )
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
        swap_chain_adequate =
            len(swap_chain_support.formats) != 0 && len(swap_chain_support.present_modes) != 0
    }

    return(
        b32(has_graphics) &&
        b32(has_present) &&
        b32(extensions_supported) &&
        swap_chain_adequate \
    )
}

find_queue_families :: proc(
    device: vk.PhysicalDevice,
    ctx: ^AppContext,
) -> QueueFamilyIndicies {
    indicies: QueueFamilyIndicies
    present_support: b32

    count: u32
    vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)
    queue_families := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
    vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(queue_families))


    for fam, i in queue_families {
        if .GRAPHICS in fam.queueFlags {
            indicies.graphics_family = u32(i)
            vk.GetPhysicalDeviceSurfaceSupportKHR(
                device,
                u32(i),
                ctx.surface,
                &present_support,
            )
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

query_swapchain_support :: proc(
    device: vk.PhysicalDevice,
    ctx: ^AppContext,
) -> SwapchainSupportDetails {
    details: SwapchainSupportDetails

    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, ctx.surface, &details.capabilities)

    format_count: u32
    vk.GetPhysicalDeviceSurfaceFormatsKHR(device, ctx.surface, &format_count, nil)
    if format_count != 0 {
        details.formats = make([]vk.SurfaceFormatKHR, format_count, context.temp_allocator)
        vk.GetPhysicalDeviceSurfaceFormatsKHR(
            device,
            ctx.surface,
            &format_count,
            raw_data(details.formats),
        )
    }

    present_count: u32
    vk.GetPhysicalDeviceSurfacePresentModesKHR(device, ctx.surface, &present_count, nil)
    if present_count != 0 {
        details.present_modes = make(
            []vk.PresentModeKHR,
            present_count,
            context.temp_allocator,
        )
        vk.GetPhysicalDeviceSurfacePresentModesKHR(
            device,
            ctx.surface,
            &present_count,
            raw_data(details.present_modes),
        )
    }

    return details
}

choose_swap_surface_format :: proc(
    available_formats: []vk.SurfaceFormatKHR,
) -> vk.SurfaceFormatKHR {
    for av_f in available_formats {
        if av_f.format == .B8G8R8A8_SRGB && av_f.colorSpace == .SRGB_NONLINEAR {
            return av_f
        }
    }
    return available_formats[0]
}

choose_swap_present_mode :: proc(
    available_present_modes: []vk.PresentModeKHR,
) -> vk.PresentModeKHR {

    for av_p in available_present_modes {
        if av_p == .MAILBOX {
            return av_p
        }
    }
    return vk.PresentModeKHR.FIFO
}

choose_swap_extent :: proc(
    capabilities: vk.SurfaceCapabilitiesKHR,
    ctx: ^AppContext,
) -> vk.Extent2D {
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
    vk.GetSwapchainImagesKHR(
        ctx.logical_device,
        ctx.swapchain,
        &swp_image_count,
        raw_data(ctx.swapchain_images),
    )

    ctx.swapchain_extent = extent
    ctx.swapchain_image_format = surface_format.format
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
        result := vk.CreateImageView(
            ctx.logical_device,
            &create_info,
            nil,
            &ctx.swapchain_image_views[i],
        )
        log.assertf(result == .SUCCESS, "Failed to create image views with result: %v", result)
    }
}

// ========================================= VULKAN PIPELINE =========================================
create_graphics_pipeline :: proc(ctx: ^AppContext) {
    vert_handle, vert_open_ok := os.open(".\\bin\\vert.spv")
    defer os.close(vert_handle)
    frag_handle, frag_open_ok := os.open(".\\bin\\frag.spv")
    if vert_open_ok != nil || frag_open_ok != nil {
        log.panicf("Failed to open shader file - frag:%v\tvert:%v", frag_open_ok, vert_open_ok)
    }

    vert_file, vert_read_ok := os.read_entire_file_from_handle(vert_handle)
    frag_file, frag_read_ok := os.read_entire_file_from_handle(frag_handle)
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

    shader_stages: []vk.PipelineShaderStageCreateInfo = {
        vert_shader_stage_info,
        frag_shader_stage_info,
    }

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
// ========================================= WINDOW =========================================
init_window :: proc(global_context: ^AppContext) {
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
    global_context.window = window


    // TODO: look into resizing the window
}

// ========================================= DESTRUCTION =========================================
cleanup :: proc(global_context: ^AppContext) {
    when ENABLE_VALIDATION_LAYERS {
        vk.DestroyDebugUtilsMessengerEXT(
            global_context.instance,
            global_context.dbg_messenger,
            nil,
        )
    }

    for img in global_context.swapchain_image_views {
        vk.DestroyImageView(global_context.logical_device, img, nil)
    }

    vk.DestroySwapchainKHR(global_context.logical_device, global_context.swapchain, nil)
    vk.DestroyDevice(global_context.logical_device, nil)
    assert(vk.DestroyInstance != nil, "nil")
    vk.DestroySurfaceKHR(global_context.instance, global_context.surface, nil)
    vk.DestroyInstance(global_context.instance, nil)

    SDL.Vulkan_UnloadLibrary()
    SDL.DestroyWindow(global_context.window)
    SDL.Quit()

    delete(global_context.swapchain_image_views)
    delete(global_context.swapchain_images)
}
