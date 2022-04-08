const std = @import("std");
const glfw = @import("glfw");
const alloc = @import("allocators.zig");
const util = @import("util.zig");
const c = @import("c.zig");

const cstr_z = [*:0]const u8;
const cstr = [*c]const u8;

pub fn checkVk(err: c.VkResult) callconv(.C) void {
    if (err == 0) return;

    std.debug.print("[vulkan] Error: VkResult = {}\n", .{err});
    if (err < 0)
        @panic("[vulkan] aborted");
}

// This maybe *should* have VKAPI_ATTR or VKAPI_CALL in there, but they're C
// macros. Unsure where they go here.
//                              - Albert Liu, Apr 06, 2022 Wed 23:58 EDT
pub fn dbg(
    flags: c.VkDebugReportFlagsEXT,
    objectType: c.VkDebugReportObjectTypeEXT,
    object: u64,
    location: usize,
    messageCode: i32,
    pLayerPrefix: cstr,
    pMessage: cstr,
    pUserData: ?*anyopaque,
) callconv(.C) c.VkBool32 {
    _ = flags;
    _ = object;
    _ = location;
    _ = messageCode;
    _ = pLayerPrefix;
    _ = pUserData;

    const fmt = "[vulkan] Debug report from ObjectType: {}\nMessage: {s}\n\n";
    std.debug.print(fmt, .{ objectType, pMessage });

    return c.VK_FALSE;
}

pub var g_Instance: c.VkInstance = null;
pub var g_PhysicalDevice: c.VkPhysicalDevice = null;
pub var g_Device: c.VkDevice = null;
pub var g_QueueFamily: u32 = std.math.maxInt(u32);
var g_Queue: c.VkQueue = null;
var g_DebugReport: c.VkDebugReportCallbackEXT = null;
var g_DescriptorPool: c.VkDescriptorPool = null;
pub var g_MainWindowData: c.ImGui_ImplVulkanH_Window = c.ImGui_ImplVulkanH_Window{
    .Width = 0,
    .Height = 0,
    .Swapchain = null,
    .Surface = null,
    .SurfaceFormat = .{ .format = 0, .colorSpace = 0 },
    .PresentMode = c.VK_PRESENT_MODE_MAX_ENUM_KHR,
    .RenderPass = null,
    .Pipeline = null,
    .ClearEnable = true,
    .ClearValue = undefined,
    .FrameIndex = 0,
    .ImageCount = 0,
    .SemaphoreIndex = 0,
    .Frames = null,
    .FrameSemaphores = null,
};

// All the ImGui_ImplVulkanH_XXX structures/functions are optional helpers used
// by the demo. Your real engine/app may not use them.
pub fn setupVulkan(window: glfw.Window, width: c_int, height: c_int) !void {
    var _temp = alloc.Temp.init();
    const temp = _temp.allocator();
    defer _temp.deinit();

    var err: c.VkResult = undefined;

    {
        const glfw_ext = try glfw.getRequiredInstanceExtensions();
        const count = std.math.cast(u32, glfw_ext.len) catch @panic("oof");

        const ext = try temp.alloc(cstr_z, count + 1);
        std.mem.copy(cstr_z, ext, glfw_ext.ptr[0..glfw_ext.len]);

        ext[count] = "VK_EXT_debug_report";

        const layers: []const cstr = &[_]cstr{"VK_LAYER_KHRONOS_validation"};
        const create_info = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .enabledExtensionCount = count + 1,
            .ppEnabledExtensionNames = ext.ptr,
            .enabledLayerCount = 1,
            .ppEnabledLayerNames = layers.ptr,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = 0,
        };

        err = c.vkCreateInstance(&create_info, null, &g_Instance);
        checkVk(err);

        const callback = cb: {
            const name = "vkCreateDebugReportCallbackEXT";
            const raw_callback = c.vkGetInstanceProcAddr(g_Instance, name);
            if (@ptrCast(c.PFN_vkCreateDebugReportCallbackEXT, raw_callback)) |cb| {
                break :cb cb;
            }

            @panic("rip");
        };

        var debug_report_ci = c.VkDebugReportCallbackCreateInfoEXT{
            .sType = c.VK_STRUCTURE_TYPE_DEBUG_REPORT_CALLBACK_CREATE_INFO_EXT,
            .flags = c.VK_DEBUG_REPORT_ERROR_BIT_EXT |
                c.VK_DEBUG_REPORT_WARNING_BIT_EXT |
                c.VK_DEBUG_REPORT_PERFORMANCE_WARNING_BIT_EXT,
            .pfnCallback = dbg,
            .pNext = null,
            .pUserData = null,
        };

        err = callback(g_Instance, &debug_report_ci, null, &g_DebugReport);
        checkVk(err);
    }

    // Select GPU
    g_PhysicalDevice = select_gpu: {
        var count: u32 = 0;
        err = c.vkEnumeratePhysicalDevices(g_Instance, &count, null);
        checkVk(err);
        std.debug.assert(count > 0);

        const gpus = try temp.alloc(c.VkPhysicalDevice, count);
        err = c.vkEnumeratePhysicalDevices(g_Instance, &count, gpus.ptr);
        checkVk(err);

        // If a number >1 of GPUs got reported, find discrete GPU if present, or use
        // first one available. This covers most common cases
        // (multi-gpu/integrated+dedicated graphics). Handling more complicated
        // setups (multiple dedicated GPUs) is out of scope of this sample.
        for (gpus) |gpu| {
            var properties: c.VkPhysicalDeviceProperties = undefined;
            c.vkGetPhysicalDeviceProperties(gpu, &properties);

            if (properties.deviceType != c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU)
                continue;

            break :select_gpu gpu;
        }

        break :select_gpu gpus[0];
    };

    // Select graphics queue family
    g_QueueFamily = queue_family: {
        const getProperties = c.vkGetPhysicalDeviceQueueFamilyProperties;

        var count: u32 = 0;
        getProperties(g_PhysicalDevice, &count, null);
        const queues = try temp.alloc(c.VkQueueFamilyProperties, count);
        getProperties(g_PhysicalDevice, &count, queues.ptr);

        for (queues) |queue, i| {
            const mask = queue.queueFlags & c.VK_QUEUE_GRAPHICS_BIT;
            if (mask != 0) {
                break :queue_family std.math.cast(u32, i) catch @panic("rippo");
            }
        }

        @panic("couldn't get queue family");
    };

    // Create Logical Device (with 1 queue)
    {
        const device_extensions = [_]cstr{"VK_KHR_swapchain"};
        const queue_priority = [_]f32{1.0};
        var queue_info = [_]c.VkDeviceQueueCreateInfo{
            .{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = g_QueueFamily,
                .queueCount = 1,
                .pQueuePriorities = &queue_priority,
                .pNext = null,
                .flags = 0,
            },
        };

        var create_info = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = queue_info.len,
            .pQueueCreateInfos = &queue_info,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = &device_extensions,
            .pNext = null,
            .flags = 0,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .pEnabledFeatures = null,
        };

        err = c.vkCreateDevice(g_PhysicalDevice, &create_info, null, &g_Device);
        checkVk(err);

        c.vkGetDeviceQueue(g_Device, g_QueueFamily, 0, &g_Queue);
    }

    {
        const pool_sizes = [_]c.VkDescriptorPoolSize{
            .{ .@"type" = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 1000 },
            .{
                .@"type" = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .descriptorCount = 1000,
            },
            .{
                .@"type" = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
                .descriptorCount = 1000,
            },
            .{
                .@"type" = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
                .descriptorCount = 1000,
            },
            .{
                .@"type" = c.VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER,
                .descriptorCount = 1000,
            },
            .{
                .@"type" = c.VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER,
                .descriptorCount = 1000,
            },
            .{
                .@"type" = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .descriptorCount = 1000,
            },
            .{
                .@"type" = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1000,
            },
            .{
                .@"type" = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
                .descriptorCount = 1000,
            },
            .{
                .@"type" = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC,
                .descriptorCount = 1000,
            },
            .{
                .@"type" = c.VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
                .descriptorCount = 1000,
            },
        };

        const pool_info = c.VkDescriptorPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .flags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
            .maxSets = 1000 * pool_sizes.len,
            .poolSizeCount = pool_sizes.len,
            .pPoolSizes = &pool_sizes,
            .pNext = null,
        };
        err = c.vkCreateDescriptorPool(g_Device, &pool_info, null, &g_DescriptorPool);
        checkVk(err);
    }

    const wd = &g_MainWindowData;

    {
        // Create Window Surface
        err = try glfw.createWindowSurface(g_Instance, window, null, &wd.Surface);
        checkVk(err);

        // Check for WSI support
        var res: c.VkBool32 = undefined;
        _ = c.vkGetPhysicalDeviceSurfaceSupportKHR(g_PhysicalDevice, g_QueueFamily, wd.Surface, &res);
        if (res != c.VK_TRUE) {
            @panic("Error no WSI support on physical device 0\n");
        }

        const imageFormat = [_]c.VkFormat{
            c.VK_FORMAT_B8G8R8A8_UNORM, c.VK_FORMAT_R8G8B8A8_UNORM,
            c.VK_FORMAT_B8G8R8_UNORM,   c.VK_FORMAT_R8G8B8_UNORM,
        };
        const colorSpace = c.VK_COLORSPACE_SRGB_NONLINEAR_KHR;
        wd.SurfaceFormat = c.ImGui_ImplVulkanH_SelectSurfaceFormat(
            g_PhysicalDevice,
            wd.Surface,
            &imageFormat,
            imageFormat.len,
            colorSpace,
        );

        const present_modes = [_]c.VkPresentModeKHR{
            c.VK_PRESENT_MODE_MAILBOX_KHR, c.VK_PRESENT_MODE_IMMEDIATE_KHR,
            c.VK_PRESENT_MODE_FIFO_KHR,
        };
        wd.PresentMode = c.ImGui_ImplVulkanH_SelectPresentMode(g_PhysicalDevice, wd.Surface, &present_modes, present_modes.len);

        // Create SwapChain, RenderPass, Framebuffer, etc.
        c.ImGui_ImplVulkanH_CreateOrResizeWindow(g_Instance, g_PhysicalDevice, g_Device, wd, g_QueueFamily, null, width, height, 2);
    }

    // Setup Platform/Renderer backends
    {
        // They're the same struct type, but defined in different includes of the
        // same header
        const handle = @ptrCast(*c.struct_GLFWwindow, window.handle);

        _ = c.ImGui_ImplGlfw_InitForVulkan(handle, true);
        var init_info = c.ImGui_ImplVulkan_InitInfo{
            .Instance = g_Instance,
            .PhysicalDevice = g_PhysicalDevice,
            .Device = g_Device,
            .QueueFamily = g_QueueFamily,
            .Queue = g_Queue,
            .PipelineCache = null,
            .DescriptorPool = g_DescriptorPool,
            .Subpass = 0,
            .MinImageCount = 2,
            .ImageCount = wd.ImageCount,
            .MSAASamples = c.VK_SAMPLE_COUNT_1_BIT,
            .Allocator = null,
            .CheckVkResultFn = checkVk,
        };
        _ = c.ImGui_ImplVulkan_Init(&init_info, wd.RenderPass);
    }

    // Load Fonts
    // - If no fonts are loaded, dear imgui will use the default font. You can
    // also load multiple fonts and use ImGui::PushFont()/PopFont() to select
    // them.
    // - AddFontFromFileTTF() will return the ImFont* so you can store it if you
    // need to select the font among multiple.
    // - If the file cannot be loaded, the function will return NULL. Please
    // handle those errors in your application (e.g. use an assertion, or display
    // an error and quit).
    // - The fonts will be rasterized at a given size (w/ oversampling) and stored
    // into a texture when calling ImFontAtlas::Build()/GetTexDataAsXXXX(), which
    // ImGui_ImplXXXX_NewFrame below will call.
    // - Read 'docs/FONTS.md' for more instructions and details.
    // - Remember that in C/C++ if you want to include a backslash \ in a string
    // literal you need to write a double backslash \\ !
    // io.Fonts->AddFontDefault();
    // io.Fonts->AddFontFromFileTTF("../../misc/fonts/Roboto-Medium.ttf", 16.0f);
    // io.Fonts->AddFontFromFileTTF("../../misc/fonts/Cousine-Regular.ttf", 15.0f);
    // io.Fonts->AddFontFromFileTTF("../../misc/fonts/DroidSans.ttf", 16.0f);
    // io.Fonts->AddFontFromFileTTF("../../misc/fonts/ProggyTiny.ttf", 10.0f);
    // ImFont* font =
    // io.Fonts->AddFontFromFileTTF("c:\\Windows\\Fonts\\ArialUni.ttf", 18.0f,
    // NULL, io.Fonts->GetGlyphRangesJapanese()); IM_ASSERT(font != NULL);
    {
        const frame = wd.Frames[wd.FrameIndex];

        // Use any command queue
        const command_pool = frame.CommandPool;
        const command_buffer = frame.CommandBuffer;

        err = c.vkResetCommandPool(g_Device, command_pool, 0);
        checkVk(err);

        const begin_info = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pNext = null,
            .pInheritanceInfo = null,
        };
        err = c.vkBeginCommandBuffer(command_buffer, &begin_info);
        checkVk(err);

        _ = c.ImGui_ImplVulkan_CreateFontsTexture(command_buffer);

        const end_info = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &command_buffer,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
            .pWaitDstStageMask = null,
        };
        err = c.vkEndCommandBuffer(command_buffer);
        checkVk(err);
        err = c.vkQueueSubmit(g_Queue, 1, &end_info, null);
        checkVk(err);

        err = c.vkDeviceWaitIdle(g_Device);
        checkVk(err);

        c.ImGui_ImplVulkan_DestroyFontUploadObjects();
    }
}

pub fn renderFrame(wd: *c.ImGui_ImplVulkanH_Window, draw_data: *c.ImDrawData) bool {
    var err: c.VkResult = undefined;

    const semaphores = wd.FrameSemaphores[wd.SemaphoreIndex];
    var image_acquired_semaphore = semaphores.ImageAcquiredSemaphore;
    var render_complete_semaphore = semaphores.RenderCompleteSemaphore;

    const U64_MAX = std.math.maxInt(u64);

    err = c.vkAcquireNextImageKHR(g_Device, wd.Swapchain, U64_MAX, image_acquired_semaphore, null, &wd.FrameIndex);

    if (err == c.VK_ERROR_OUT_OF_DATE_KHR or err == c.VK_SUBOPTIMAL_KHR) {
        return true;
    }

    checkVk(err);

    const fd = &wd.Frames[wd.FrameIndex];

    {
        // wait indefinitely instead of periodically checking
        err = c.vkWaitForFences(g_Device, 1, &fd.Fence, c.VK_TRUE, U64_MAX);
        checkVk(err);

        err = c.vkResetFences(g_Device, 1, &fd.Fence);
        checkVk(err);
    }

    {
        err = c.vkResetCommandPool(g_Device, fd.CommandPool, 0);
        checkVk(err);
        var info = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
            .pNext = null,
        };

        err = c.vkBeginCommandBuffer(fd.CommandBuffer, &info);
        checkVk(err);
    }

    {
        const extent = .{
            .width = std.math.cast(u32, wd.Width) catch @panic("whoops"),
            .height = std.math.cast(u32, wd.Height) catch @panic("whoops"),
        };
        var info = c.VkRenderPassBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = wd.RenderPass,
            .framebuffer = fd.Framebuffer,
            .clearValueCount = 1,
            .pClearValues = &wd.ClearValue,
            .renderArea = .{
                .extent = extent,
                .offset = .{ .x = 0, .y = 0 },
            },
            .pNext = null,
        };

        c.vkCmdBeginRenderPass(fd.CommandBuffer, &info, c.VK_SUBPASS_CONTENTS_INLINE);
    }

    // Record dear imgui primitives into command buffer
    c.ImGui_ImplVulkan_RenderDrawData(draw_data, fd.CommandBuffer, null);

    // Submit command buffer
    c.vkCmdEndRenderPass(fd.CommandBuffer);
    {
        const wait_stage: u32 =
            c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        var info = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &image_acquired_semaphore,
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &fd.CommandBuffer,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &render_complete_semaphore,
            .pNext = null,
        };

        err = c.vkEndCommandBuffer(fd.CommandBuffer);
        checkVk(err);
        err = c.vkQueueSubmit(g_Queue, 1, &info, fd.Fence);
        checkVk(err);
    }

    {
        const info = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &render_complete_semaphore,
            .swapchainCount = 1,
            .pSwapchains = &wd.Swapchain,
            .pImageIndices = &wd.FrameIndex,
            .pNext = null,
            .pResults = null,
        };

        err = c.vkQueuePresentKHR(g_Queue, &info);
        if (err == c.VK_ERROR_OUT_OF_DATE_KHR or err == c.VK_SUBOPTIMAL_KHR) {
            return true;
        }

        checkVk(err);

        // Now we can use the next set of semaphores
        wd.SemaphoreIndex = (wd.SemaphoreIndex + 1) % wd.ImageCount;
    }

    return false;
}

pub fn teardownVulkan() void {
    const err = c.vkDeviceWaitIdle(g_Device);
    checkVk(err);

    c.ImGui_ImplVulkan_Shutdown();
    c.ImGui_ImplGlfw_Shutdown();

    c.ImGui_ImplVulkanH_DestroyWindow(g_Instance, g_Device, &g_MainWindowData, null);

    c.vkDestroyDescriptorPool(g_Device, g_DescriptorPool, null);

    const callback = cb: {
        const name = "vkDestroyDebugReportCallbackEXT";
        const raw_callback = c.vkGetInstanceProcAddr(g_Instance, name);
        if (@ptrCast(c.PFN_vkDestroyDebugReportCallbackEXT, raw_callback)) |cb| {
            break :cb cb;
        }

        @panic("rip");
    };

    callback(g_Instance, g_DebugReport, null);

    c.vkDestroyDevice(g_Device, null);
    c.vkDestroyInstance(g_Instance, null);
}
