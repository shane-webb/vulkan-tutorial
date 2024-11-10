package main

import "base:runtime"
import "core:log"
import "core:mem"
// import SDL "vendor:sdl2"
import "vendor:glfw"
import vk "vendor:vulkan"

WINDOW_WIDTH :: 1920
WINDOW_HEIGHT :: 1080

GLOBAL_RUNTIME_CONTEXT: runtime.Context

AppContext :: struct {
    dbg_messenger:    vk.DebugUtilsMessengerEXT,
    dbg_messenger_CI: vk.DebugUtilsMessengerCreateInfoEXT,
    instance:         vk.Instance,
    // window:           ^SDL.Window,
    window:           glfw.WindowHandle,
}


logger: log.Logger
ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, ODIN_DEBUG)
// VK_LAYER_KRONOS_validation comes from the LunarG SDK
// there are other validation layers that can be used
VALIDATION_LAYERS := []cstring{"VK_LAYER_KHRONOS_validation"}

main :: proc() {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)
    GLOBAL_RUNTIME_CONTEXT = context

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

// ========================================= VULKAN =========================================
init_vulkan :: proc(ctx: ^AppContext) {
    vk.load_proc_addresses_global(SDL.Vulkan_GetVkGetInstanceProcAddr())
    assert(vk.CreateInstance != nil, "Vulkan function pointers not loaded")

    create_instance(ctx)
    vk.load_proc_addresses_instance(ctx.instance)

    when ENABLE_VALIDATION_LAYERS {
        setup_debug_messenger(ctx)
    }

    free_all(context.temp_allocator)
}

create_instance :: proc(ctx: ^AppContext) {
    app_info := vk.ApplicationInfo {
        sType            = vk.StructureType.APPLICATION_INFO,
        pApplicationName = "Odin VkGuide",
        pEngineName      = "No Engine",
        engineVersion    = vk.MAKE_VERSION(1, 3, 0),
        apiVersion       = vk.API_VERSION_1_3,
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
        if !check_validation_layer_support() {
            log.error("The requested validation layers are not supported")
            return
        }
        ctx.dbg_messenger_CI = vk.DebugUtilsMessengerCreateInfoEXT {
            sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            messageSeverity = {.VERBOSE, .INFO, .WARNING, .ERROR},
            messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE, .DEVICE_ADDRESS_BINDING},
            pfnUserCallback = vk_messenger_callback,
            pUserData       = nil,
        }
        log.info("Validation layers enabled")
        instance_CI.ppEnabledLayerNames = raw_data(VALIDATION_LAYERS)
        instance_CI.enabledLayerCount = u32(len(VALIDATION_LAYERS))
        instance_CI.pNext = &ctx.dbg_messenger_CI
    } else {
        instance_CI.enabledLayerCount = 0
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
    for &ext in instance_extensions do log.infof("Extension: %s", cstring(&ext.extensionName[0]))
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
            log.infof("Instance Layer Property: %s", prop)
            if name == prop {
                log.infof("Validation layer %q found", name)
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
        append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

    }

    return extensions
}


vk_messenger_callback :: proc "system" (
    messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
    messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
    pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
    pUserData: rawptr,
) -> b32 {
    context = GLOBAL_RUNTIME_CONTEXT

    level: log.Level
    switch messageSeverity {
    case {.ERROR}:
        level = .Error
    case {.WARNING}:
        level = .Warning
    case {.INFO}:
        level = .Info
    case:
        level = .Debug
    }

    log.logf(level, "Vulkan[%v]: %s", messageTypes, pCallbackData.pMessage)
    return false
}




// odinfmt: disable
setup_debug_messenger :: proc(ctx: ^AppContext) {
    // debug messenger is an extension function so it needs to be loaded separately
    vk.CreateDebugUtilsMessengerEXT =
        auto_cast vk.GetInstanceProcAddr(ctx.instance, "vkCreateDebugUtilsMessengerEXT")
    assert(vk.CreateDebugUtilsMessengerEXT != nil, "Create debug messenger proc address is nil")
    log.info()
    log.infof("%T", vk.CreateDebugUtilsMessengerEXT)

    vk.DestroyDebugUtilsMessengerEXT = 
        auto_cast vk.GetInstanceProcAddr(ctx.instance, "vkDestroyDebugUtilsMessengerEXT")
    assert(vk.DestroyDebugUtilsMessengerEXT != nil, "Destroy debug messenger proc address is nil")

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


    result := vk.CreateDebugUtilsMessengerEXT(ctx.instance, &ctx.dbg_messenger_CI, nil, &ctx.dbg_messenger)
    log.assertf(result == .SUCCESS, "Debug messenger creation failed with result: %v", result)
} // odinfmt: enable


// ========================================= WINDOW =========================================
init_window :: proc(global_context: ^AppContext) {
    // SDL.Init({.VIDEO})
    // SDL.Vulkan_LoadLibrary(nil)
    // window := SDL.CreateWindow(
    //     "Odin Vulkan Again",
    //     SDL.WINDOWPOS_UNDEFINED,
    //     SDL.WINDOWPOS_UNDEFINED,
    //     WINDOW_WIDTH,
    //     WINDOW_HEIGHT,
    //     {.SHOWN, .VULKAN},
    // )
    // if window == nil {
    //     log.error("Failed to create window")
    //     return
    // }
    // global_context.window = window

    glfw.Init()
    // tell glfw to not create an OpenGL context
    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
    // disable window resizing
    glfw.WindowHint(glfw.RESIZABLE, 0)

    global_context.window = glfw.CreateWindow(
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        "first triangle",
        nil,
        nil,
    )
    glfw.SetWindowUserPointer(global_context.window, global_context)


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

    assert(vk.DestroyInstance != nil, "nil")
    // vk.DestroyInstance(global_context.instance, nil)

    SDL.Vulkan_UnloadLibrary()
    SDL.DestroyWindow(global_context.window)
    SDL.Quit()
}
