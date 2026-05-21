//! Native Windows 11 demo window, input, clock, and Vulkan surface glue.
//!
//! USER32 still owns the documented class, message-loop, DPI, and Vulkan WSI
//! ABI. One-to-one lower-level operations use win32u/ntdll directly where the
//! Windows 11 NtUser entry points have stable signatures in current phnt.

const std = @import("std");
const windows = std.os.windows;
const ntdll = windows.ntdll;
const vk = @import("vulkan");
const demo_input = @import("demo_input");
const demo_title = @import("demo_title");

const HRESULT = windows.LONG;
const LRESULT = isize;
const WPARAM = usize;

const WndProc = *const fn (
    hwnd: windows.HWND,
    msg: windows.UINT,
    wparam: WPARAM,
    lparam: windows.LPARAM,
) callconv(.winapi) LRESULT;

const DwmSetWindowAttributeFn = *const fn (
    hwnd: windows.HWND,
    dwAttribute: windows.DWORD,
    pvAttribute: windows.LPCVOID,
    cbAttribute: windows.DWORD,
) callconv(.winapi) HRESULT;

const POINT = extern struct {
    x: windows.LONG,
    y: windows.LONG,
};

const MSG = extern struct {
    hwnd: ?windows.HWND,
    message: windows.UINT,
    wParam: WPARAM,
    lParam: windows.LPARAM,
    time: windows.DWORD,
    pt: POINT,
};

const RECT = extern struct {
    left: windows.LONG,
    top: windows.LONG,
    right: windows.LONG,
    bottom: windows.LONG,
};

const WNDCLASSEXW = extern struct {
    cbSize: windows.UINT = @sizeOf(WNDCLASSEXW),
    style: windows.UINT,
    lpfnWndProc: WndProc,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: windows.HINSTANCE,
    hIcon: ?windows.HICON = null,
    hCursor: ?windows.HCURSOR = null,
    hbrBackground: ?windows.HBRUSH = null,
    lpszMenuName: ?windows.LPCWSTR = null,
    lpszClassName: windows.LPCWSTR,
    hIconSm: ?windows.HICON = null,
};

const CREATESTRUCTW = extern struct {
    lpCreateParams: ?windows.LPVOID,
    hInstance: windows.HINSTANCE,
    hMenu: ?windows.HMENU,
    hwndParent: ?windows.HWND,
    cy: c_int,
    cx: c_int,
    y: c_int,
    x: c_int,
    style: windows.LONG,
    lpszName: windows.LPCWSTR,
    lpszClass: windows.LPCWSTR,
    dwExStyle: windows.DWORD,
};

extern "user32" fn AdjustWindowRectExForDpi(
    lpRect: *RECT,
    dwStyle: windows.DWORD,
    bMenu: windows.BOOL,
    dwExStyle: windows.DWORD,
    dpi: windows.UINT,
) callconv(.winapi) windows.BOOL;
extern "user32" fn CreateWindowExW(
    dwExStyle: windows.DWORD,
    lpClassName: windows.LPCWSTR,
    lpWindowName: windows.LPCWSTR,
    dwStyle: windows.DWORD,
    X: c_int,
    Y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: ?windows.HWND,
    hMenu: ?windows.HMENU,
    hInstance: windows.HINSTANCE,
    lpParam: ?windows.LPVOID,
) callconv(.winapi) ?windows.HWND;
extern "user32" fn DefWindowProcW(
    hwnd: windows.HWND,
    msg: windows.UINT,
    wparam: WPARAM,
    lparam: windows.LPARAM,
) callconv(.winapi) LRESULT;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn GetClientRect(hWnd: windows.HWND, lpRect: *RECT) callconv(.winapi) windows.BOOL;
extern "user32" fn GetDpiForWindow(hwnd: windows.HWND) callconv(.winapi) windows.UINT;
extern "user32" fn GetWindowLongPtrW(hWnd: windows.HWND, nIndex: c_int) callconv(.winapi) windows.LONG_PTR;
extern "user32" fn LoadCursorW(hInstance: ?windows.HINSTANCE, lpCursorName: windows.LPCWSTR) callconv(.winapi) ?windows.HCURSOR;
extern "user32" fn PeekMessageW(
    lpMsg: *MSG,
    hWnd: ?windows.HWND,
    wMsgFilterMin: windows.UINT,
    wMsgFilterMax: windows.UINT,
    wRemoveMsg: windows.UINT,
) callconv(.winapi) windows.BOOL;
extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) windows.ATOM;
extern "user32" fn ScreenToClient(hWnd: windows.HWND, lpPoint: *POINT) callconv(.winapi) windows.BOOL;
extern "user32" fn SetWindowLongPtrW(
    hWnd: windows.HWND,
    nIndex: c_int,
    dwNewLong: windows.LONG_PTR,
) callconv(.winapi) windows.LONG_PTR;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) windows.BOOL;

const Win32 = struct {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("HeavySlugDemoWindow");

    const ModuleName = struct {
        const dwmapi = std.unicode.utf8ToUtf16LeStringLiteral("dwmapi.dll");
        const win32u = std.unicode.utf8ToUtf16LeStringLiteral("win32u.dll");
        const vulkan_loader = std.unicode.utf8ToUtf16LeStringLiteral("vulkan-1.dll");
    };

    const Dpi = struct {
        const base: windows.UINT = 96;
    };

    const Dwm = struct {
        const use_immersive_dark_mode: windows.DWORD = 20;
        const window_corner_preference: windows.DWORD = 33;
        const border_color: windows.DWORD = 34;
        const caption_color: windows.DWORD = 35;
        const text_color: windows.DWORD = 36;
    };

    const ErrorCode = struct {
        const class_already_exists = windows.Win32Error.CLASS_ALREADY_EXISTS;
    };

    const Message = struct {
        const destroy = 0x0002;
        const size = 0x0005;
        const kill_focus = 0x0008;
        const close = 0x0010;
        const quit = 0x0012;
        const erase_background = 0x0014;
        const activate_app = 0x001C;
        const cancel_mode = 0x001F;
        const nccreate = 0x0081;
        const ncdestroy = 0x0082;
        const key_down = 0x0100;
        const key_up = 0x0101;
        const sys_key_down = 0x0104;
        const sys_key_up = 0x0105;
        const mouse_move = 0x0200;
        const left_button_down = 0x0201;
        const left_button_up = 0x0202;
        const right_button_down = 0x0204;
        const right_button_up = 0x0205;
        const mouse_wheel = 0x020A;
        const capture_changed = 0x0215;
        const dpi_changed = 0x02E0;
    };

    const Peek = struct {
        const remove = 0x0001;
    };

    const Pointer = struct {
        const arrow: windows.LPCWSTR = @ptrFromInt(32512);
    };

    const Show = struct {
        const normal = 5;
    };

    const Style = struct {
        const caption: windows.DWORD = 0x00C00000;
        const sysmenu: windows.DWORD = 0x00080000;
        const thickframe: windows.DWORD = 0x00040000;
        const minimizebox: windows.DWORD = 0x00020000;
        const maximizebox: windows.DWORD = 0x00010000;
        const standard_titled_window: windows.DWORD = caption | sysmenu | thickframe | minimizebox | maximizebox;
    };

    const WindowPosition = struct {
        const no_move = 0x0002;
        const no_z_order = 0x0004;
        const no_activate = 0x0010;
    };

    const VirtualKey = struct {
        const escape = 0x1B;
        const space = 0x20;
        const left = 0x25;
        const up = 0x26;
        const right = 0x27;
        const down = 0x28;
        const b = 0x42;
        const r = 0x52;
        const oem_minus = 0xBD;
        const oem_plus = 0xBB;
        const subtract = 0x6D;
        const add = 0x6B;
    };

    const WindowLong = struct {
        const user_data = -21;
    };

    const wheel_delta = 120.0;
    const use_default_position = std.math.minInt(c_int);
};

const ChromeTheme = enum {
    light,
    dark,
};

const ChromePalette = struct {
    caption: windows.COLORREF,
    text: windows.COLORREF,
    border: windows.COLORREF,
};

pub const SurfaceCapabilities = struct {
    direct_swapchain: bool = true,
    /// Vulkan owns the HWND swapchain memory contract. DXGI shared handles and
    /// NT sections are external-memory tools, not the Win32 WSI present path.
    external_memory: ExternalMemory = .not_used_for_vulkan_wsi,
    shared_section: SharedSection = .not_used_for_vulkan_wsi,

    pub const ExternalMemory = enum {
        not_used_for_vulkan_wsi,
    };

    pub const SharedSection = enum {
        not_used_for_vulkan_wsi,
    };

    pub fn supportsDirectSwapchain(self: SurfaceCapabilities) bool {
        return self.direct_swapchain;
    }
};

const DwmWindowCornerPreference = enum(windows.DWORD) {
    default = 0,
    do_not_round = 1,
    round = 2,
    round_small = 3,
};

const NativeDll = struct {
    handle: windows.PVOID,

    fn load(name: [:0]const u16) !NativeDll {
        var dll_name = windows.UNICODE_STRING.initZ(name);
        var handle: windows.PVOID = undefined;
        const status = ntdll.LdrLoadDll(null, null, &dll_name, &handle);
        if (status != .SUCCESS) return error.NativeDllLoadFailed;
        return .{ .handle = handle };
    }

    fn procedure(self: NativeDll, comptime T: type, name: [:0]const u8) ?T {
        var proc_name = windows.ANSI_STRING.initZ(name);
        var address: windows.PVOID = undefined;
        const status = ntdll.LdrGetProcedureAddress(self.handle, &proc_name, 0, &address);
        if (status != .SUCCESS) return null;
        return @ptrCast(address);
    }

    fn requiredProcedure(self: NativeDll, comptime T: type, name: [:0]const u8) !T {
        return self.procedure(T, name) orelse error.NativeProcedureUnavailable;
    }
};

const NativeUser = struct {
    destroy_window: NtUserDestroyWindowFn,
    release_capture: NtUserReleaseCaptureFn,
    set_capture: NtUserSetCaptureFn,
    set_window_pos: NtUserSetWindowPosFn,
    show_window: NtUserShowWindowFn,

    const NtUserDestroyWindowFn = *const fn (windows.HWND) callconv(.winapi) windows.BOOL;
    const NtUserReleaseCaptureFn = *const fn () callconv(.winapi) windows.LOGICAL;
    const NtUserSetCaptureFn = *const fn (windows.HWND) callconv(.winapi) ?windows.HWND;
    const NtUserSetWindowPosFn = *const fn (
        windows.HWND,
        ?windows.HWND,
        windows.LONG,
        windows.LONG,
        windows.LONG,
        windows.LONG,
        windows.ULONG,
    ) callconv(.winapi) windows.BOOL;
    const NtUserShowWindowFn = *const fn (windows.HWND, windows.LONG) callconv(.winapi) windows.BOOL;

    const Procedure = enum {
        destroy_window,
        release_capture,
        set_capture,
        set_window_pos,
        show_window,
    };

    fn load(module: NativeDll) !NativeUser {
        return .{
            .destroy_window = try module.requiredProcedure(NtUserDestroyWindowFn, procedureName(.destroy_window)),
            .release_capture = try module.requiredProcedure(NtUserReleaseCaptureFn, procedureName(.release_capture)),
            .set_capture = try module.requiredProcedure(NtUserSetCaptureFn, procedureName(.set_capture)),
            .set_window_pos = try module.requiredProcedure(NtUserSetWindowPosFn, procedureName(.set_window_pos)),
            .show_window = try module.requiredProcedure(NtUserShowWindowFn, procedureName(.show_window)),
        };
    }

    fn procedureName(procedure: Procedure) [:0]const u8 {
        return switch (procedure) {
            .destroy_window => "NtUserDestroyWindow",
            .release_capture => "NtUserReleaseCapture",
            .set_capture => "NtUserSetCapture",
            .set_window_pos => "NtUserSetWindowPos",
            .show_window => "NtUserShowWindow",
        };
    }
};

const Clock = struct {
    frequency: i64 = 0,
    origin: i64 = 0,

    fn start() !Clock {
        const frequency = try queryPerformanceFrequency();
        return .{
            .frequency = frequency,
            .origin = try queryPerformanceCounter(),
        };
    }

    fn elapsedSeconds(self: Clock) !f64 {
        if (self.frequency <= 0) return error.PerformanceCounterUnavailable;
        const now = try queryPerformanceCounter();
        return @as(f64, @floatFromInt(now - self.origin)) /
            @as(f64, @floatFromInt(self.frequency));
    }
};

const required_instance_extensions = [_][*:0]const u8{
    "VK_KHR_surface",
    "VK_KHR_win32_surface",
};

var vulkan_loader: ?NativeDll = null;
var vk_get_instance_proc_addr: ?vk.PfnGetInstanceProcAddr = null;
var win32u: ?NativeDll = null;
var native_user: ?NativeUser = null;
var dwmapi: ?NativeDll = null;
var dwm_set_window_attribute: ?DwmSetWindowAttributeFn = null;
var dwm_dark_mode_available = true;
var dwm_color_available = true;
var dwm_corner_preference_available = true;

pub const Window = struct {
    hwnd: ?windows.HWND = null,
    hinstance: ?windows.HINSTANCE = null,
    input_state: demo_input.State = .{},
    framebuffer_width: u32 = 0,
    framebuffer_height: u32 = 0,
    should_close: bool = false,
    dpi: windows.UINT = Win32.Dpi.base,
    chrome_theme: ?ChromeTheme = null,
    clock: Clock = .{},

    pub fn init(self: *Window, allocator: std.mem.Allocator, width: c_int, height: c_int, title: []const u8) !void {
        if (self.hwnd != null) return error.WindowAlreadyInitialized;

        const title_w = try demo_title.allocUtf16LeZ(allocator, title);
        defer allocator.free(title_w);

        try loadNativeUserApi();
        try loadVulkanLoader();

        const hinstance: windows.HINSTANCE = @ptrCast(windows.peb().ImageBaseAddress);
        try registerClass(hinstance);

        self.* = .{
            .hinstance = hinstance,
            .clock = try Clock.start(),
        };

        const hwnd = CreateWindowExW(
            0,
            Win32.class_name,
            title_w.ptr,
            Win32.Style.standard_titled_window,
            Win32.use_default_position,
            Win32.use_default_position,
            Win32.use_default_position,
            Win32.use_default_position,
            null,
            null,
            hinstance,
            self,
        ) orelse return error.WindowCreationFailed;
        errdefer _ = nativeUser().destroy_window(hwnd);

        self.hwnd = hwnd;
        self.updateDpiFromWindow();
        try self.resizeLogicalClientArea(width, height);
        self.refreshFramebufferSize();
        setDwmWindowCornerPreference(hwnd);
        self.setDarkMode(false);
        _ = nativeUser().show_window(hwnd, Win32.Show.normal);
    }

    pub fn deinit(self: *Window) void {
        const hwnd = self.hwnd orelse return;
        _ = SetWindowLongPtrW(hwnd, Win32.WindowLong.user_data, 0);
        _ = nativeUser().destroy_window(hwnd);
        self.hwnd = null;
    }

    pub fn pollEvents(self: *Window) void {
        var msg: MSG = undefined;
        while (PeekMessageW(&msg, null, 0, 0, Win32.Peek.remove).toBool()) {
            if (msg.message == Win32.Message.quit) {
                self.should_close = true;
                break;
            }
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        self.refreshFramebufferSize();
    }

    pub fn input(self: *Window) *demo_input.State {
        return &self.input_state;
    }

    pub fn framebufferSize(self: *const Window) [2]u32 {
        return .{ self.framebuffer_width, self.framebuffer_height };
    }

    pub fn displayScale(self: *const Window) f64 {
        return dpiScale(self.dpi);
    }

    pub fn time(self: *const Window) f64 {
        return self.clock.elapsedSeconds() catch 0.0;
    }

    pub fn setDarkMode(self: *Window, enabled: bool) void {
        const theme = chromeThemeFromDarkMode(enabled);
        if (self.chrome_theme != null and self.chrome_theme.? == theme) return;
        if (self.hwnd) |hwnd| applyDwmChromeTheme(hwnd, theme);
        self.chrome_theme = theme;
    }

    pub fn createSurface(self: *const Window, instance: vk.Instance, idisp: anytype) !vk.SurfaceKHR {
        const hwnd = self.hwnd orelse return error.WindowUnavailable;
        const hinstance = self.hinstance orelse return error.WindowUnavailable;
        const create_info = vk.Win32SurfaceCreateInfoKHR{
            .hinstance = hinstance,
            .hwnd = hwnd,
        };
        return idisp.createWin32SurfaceKHR(instance, &create_info, null) catch error.SurfaceCreationFailed;
    }

    pub fn surfaceCapabilities(_: *const Window) SurfaceCapabilities {
        return .{};
    }

    fn refreshFramebufferSize(self: *Window) void {
        const hwnd = self.hwnd orelse {
            self.framebuffer_width = 0;
            self.framebuffer_height = 0;
            return;
        };
        const size = clientSize(hwnd) orelse return;
        self.framebuffer_width = size[0];
        self.framebuffer_height = size[1];
    }

    fn updateDpiFromWindow(self: *Window) void {
        const hwnd = self.hwnd orelse return;
        const dpi = GetDpiForWindow(hwnd);
        if (dpi != 0) self.dpi = dpi;
    }

    fn resizeLogicalClientArea(self: *Window, width: c_int, height: c_int) !void {
        const hwnd = self.hwnd orelse return error.WindowUnavailable;
        self.updateDpiFromWindow();

        var rect = RECT{
            .left = 0,
            .top = 0,
            .right = try scaleForDpi(width, self.dpi),
            .bottom = try scaleForDpi(height, self.dpi),
        };
        if (!AdjustWindowRectExForDpi(
            &rect,
            Win32.Style.standard_titled_window,
            .FALSE,
            0,
            self.dpi,
        ).toBool()) {
            return error.WindowRectFailed;
        }
        if (!nativeUser().set_window_pos(
            hwnd,
            null,
            0,
            0,
            rect.right - rect.left,
            rect.bottom - rect.top,
            Win32.WindowPosition.no_move | Win32.WindowPosition.no_z_order | Win32.WindowPosition.no_activate,
        ).toBool()) {
            return error.WindowResizeFailed;
        }
    }
};

pub fn getRequiredInstanceExtensions() []const [*:0]const u8 {
    return &required_instance_extensions;
}

pub fn getInstanceProcAddress(instance: vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction {
    const get_proc = vk_get_instance_proc_addr orelse return null;
    return get_proc(instance, name);
}

fn loadNativeUserApi() !void {
    if (native_user != null) return;

    const module = NativeDll.load(Win32.ModuleName.win32u) catch return error.NativeUserApiUnavailable;
    const api = NativeUser.load(module) catch return error.NativeUserApiUnavailable;
    win32u = module;
    native_user = api;
}

fn nativeUser() NativeUser {
    return native_user orelse unreachable;
}

fn loadVulkanLoader() !void {
    if (vk_get_instance_proc_addr != null) return;

    const loader = NativeDll.load(Win32.ModuleName.vulkan_loader) catch return error.VulkanLoaderUnavailable;
    const proc = loader.procedure(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse {
        return error.VulkanLoaderUnavailable;
    };
    vulkan_loader = loader;
    vk_get_instance_proc_addr = proc;
}

fn loadDwmSetWindowAttribute() ?DwmSetWindowAttributeFn {
    if (dwm_set_window_attribute) |proc| return proc;

    const module = NativeDll.load(Win32.ModuleName.dwmapi) catch return null;
    const proc = module.procedure(DwmSetWindowAttributeFn, "DwmSetWindowAttribute") orelse return null;
    dwmapi = module;
    dwm_set_window_attribute = proc;
    return proc;
}

fn setDwmAttribute(hwnd: windows.HWND, attribute: windows.DWORD, comptime T: type, value: *const T) bool {
    const set_window_attribute = loadDwmSetWindowAttribute() orelse return false;
    return set_window_attribute(hwnd, attribute, @ptrCast(value), @sizeOf(T)) >= 0;
}

fn setDwmWindowCornerPreference(hwnd: windows.HWND) void {
    if (!dwm_corner_preference_available) return;

    const preference: DwmWindowCornerPreference = .round;
    if (!setDwmAttribute(hwnd, Win32.Dwm.window_corner_preference, DwmWindowCornerPreference, &preference)) {
        dwm_corner_preference_available = false;
    }
}

fn applyDwmChromeTheme(hwnd: windows.HWND, theme: ChromeTheme) void {
    if (dwm_dark_mode_available) {
        const use_dark_titlebar = windows.BOOL.fromBool(theme == .dark);
        if (!setDwmAttribute(hwnd, Win32.Dwm.use_immersive_dark_mode, windows.BOOL, &use_dark_titlebar)) {
            dwm_dark_mode_available = false;
        }
    }

    if (dwm_color_available) {
        const palette = chromePalette(theme);
        if (!setDwmAttribute(hwnd, Win32.Dwm.caption_color, windows.COLORREF, &palette.caption) or
            !setDwmAttribute(hwnd, Win32.Dwm.text_color, windows.COLORREF, &palette.text) or
            !setDwmAttribute(hwnd, Win32.Dwm.border_color, windows.COLORREF, &palette.border))
        {
            dwm_color_available = false;
        }
    }
}

fn chromeThemeFromDarkMode(enabled: bool) ChromeTheme {
    return if (enabled) .dark else .light;
}

fn chromePalette(theme: ChromeTheme) ChromePalette {
    return switch (theme) {
        .light => .{
            .caption = rgb(255, 255, 255),
            .text = rgb(18, 18, 18),
            .border = rgb(214, 214, 214),
        },
        .dark => .{
            .caption = rgb(32, 32, 32),
            .text = rgb(245, 245, 245),
            .border = rgb(70, 70, 70),
        },
    };
}

fn rgb(red: u8, green: u8, blue: u8) windows.COLORREF {
    return @as(windows.COLORREF, red) |
        (@as(windows.COLORREF, green) << 8) |
        (@as(windows.COLORREF, blue) << 16);
}

fn registerClass(hinstance: windows.HINSTANCE) !void {
    const cls = WNDCLASSEXW{
        .style = 0,
        .lpfnWndProc = windowProc,
        .hInstance = hinstance,
        .hCursor = LoadCursorW(null, Win32.Pointer.arrow),
        .lpszClassName = Win32.class_name,
    };
    if (RegisterClassExW(&cls) == 0 and windows.GetLastError() != Win32.ErrorCode.class_already_exists) {
        return error.WindowClassRegistrationFailed;
    }
}

fn windowProc(hwnd: windows.HWND, msg: windows.UINT, wparam: WPARAM, lparam: windows.LPARAM) callconv(.winapi) LRESULT {
    if (msg == Win32.Message.nccreate) {
        const create: *const CREATESTRUCTW = ptrFromLparam(CREATESTRUCTW, lparam);
        const param = create.lpCreateParams orelse return 0;
        const window: *Window = @ptrCast(@alignCast(param));
        window.hwnd = hwnd;
        window.updateDpiFromWindow();
        _ = SetWindowLongPtrW(hwnd, Win32.WindowLong.user_data, windowPtrToLong(window));
        window.refreshFramebufferSize();
        return 1;
    }

    const maybe_window = windowFromHwnd(hwnd);
    switch (msg) {
        Win32.Message.close => {
            if (maybe_window) |window| window.should_close = true;
            return 0;
        },
        Win32.Message.destroy => {
            if (maybe_window) |window| window.should_close = true;
            return 0;
        },
        Win32.Message.ncdestroy => {
            releaseCapture();
            if (maybe_window) |window| {
                window.hwnd = null;
                window.input_state.clearKeys();
                window.input_state.clearMouseButtons();
            }
            _ = SetWindowLongPtrW(hwnd, Win32.WindowLong.user_data, 0);
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        Win32.Message.erase_background => return 1,
        Win32.Message.dpi_changed => {
            const suggested: *const RECT = ptrFromLparam(RECT, lparam);
            _ = nativeUser().set_window_pos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                Win32.WindowPosition.no_z_order | Win32.WindowPosition.no_activate,
            );
            if (maybe_window) |window| {
                window.dpi = dpiFromWparam(wparam);
                window.refreshFramebufferSize();
            }
            return 0;
        },
        Win32.Message.size => {
            if (maybe_window) |window| window.refreshFramebufferSize();
            return 0;
        },
        Win32.Message.kill_focus, Win32.Message.cancel_mode => {
            clearTransientInput(maybe_window);
            releaseCapture();
            return 0;
        },
        Win32.Message.activate_app => {
            if (wparam == 0) {
                clearTransientInput(maybe_window);
                releaseCapture();
            }
            return 0;
        },
        Win32.Message.key_down, Win32.Message.sys_key_down => {
            if (maybe_window) |window| {
                if (mapKey(wparam)) |key| {
                    window.input_state.setKey(key, true);
                    return 0;
                }
            }
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        Win32.Message.key_up, Win32.Message.sys_key_up => {
            if (maybe_window) |window| {
                if (mapKey(wparam)) |key| {
                    window.input_state.setKey(key, false);
                    return 0;
                }
            }
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        Win32.Message.left_button_down => {
            if (maybe_window) |window| window.input_state.setMouseButton(.left, true);
            setCapture(hwnd);
            return 0;
        },
        Win32.Message.left_button_up => {
            if (maybe_window) |window| {
                window.input_state.setMouseButton(.left, false);
                updateCapture(hwnd, window);
            }
            return 0;
        },
        Win32.Message.right_button_down => {
            if (maybe_window) |window| window.input_state.setMouseButton(.right, true);
            setCapture(hwnd);
            return 0;
        },
        Win32.Message.right_button_up => {
            if (maybe_window) |window| {
                window.input_state.setMouseButton(.right, false);
                updateCapture(hwnd, window);
            }
            return 0;
        },
        Win32.Message.capture_changed => {
            if (maybe_window) |window| window.input_state.clearMouseButtons();
            return 0;
        },
        Win32.Message.mouse_move => {
            if (maybe_window) |window| {
                const cursor = clientPointFromLparam(lparam);
                window.input_state.setCursor(cursor[0], cursor[1]);
            }
            return 0;
        },
        Win32.Message.mouse_wheel => {
            if (maybe_window) |window| {
                if (screenPointToClient(hwnd, lparam)) |cursor| {
                    window.input_state.setCursor(cursor[0], cursor[1]);
                }
                window.input_state.addScroll(wheelDeltaFromWparam(wparam));
            }
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn clearTransientInput(maybe_window: ?*Window) void {
    const window = maybe_window orelse return;
    window.input_state.clearKeys();
    window.input_state.clearMouseButtons();
}

fn setCapture(hwnd: windows.HWND) void {
    _ = nativeUser().set_capture(hwnd);
}

fn releaseCapture() void {
    _ = nativeUser().release_capture();
}

fn updateCapture(hwnd: windows.HWND, window: *Window) void {
    if (window.input_state.getMouseButton(.left) or window.input_state.getMouseButton(.right)) {
        setCapture(hwnd);
    } else {
        releaseCapture();
    }
}

fn windowFromHwnd(hwnd: windows.HWND) ?*Window {
    const ptr_value = GetWindowLongPtrW(hwnd, Win32.WindowLong.user_data);
    if (ptr_value == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr_value)));
}

fn windowPtrToLong(window: *Window) windows.LONG_PTR {
    return @as(windows.LONG_PTR, @bitCast(@intFromPtr(window)));
}

fn mapKey(wparam: WPARAM) ?demo_input.Key {
    return switch (wparam) {
        Win32.VirtualKey.escape => .escape,
        Win32.VirtualKey.space => .space,
        Win32.VirtualKey.oem_plus, Win32.VirtualKey.add => .equal,
        Win32.VirtualKey.oem_minus, Win32.VirtualKey.subtract => .minus,
        Win32.VirtualKey.b => .b,
        Win32.VirtualKey.r => .r,
        Win32.VirtualKey.up => .up,
        Win32.VirtualKey.down => .down,
        Win32.VirtualKey.left => .left,
        Win32.VirtualKey.right => .right,
        else => null,
    };
}

fn clientSize(hwnd: windows.HWND) ?[2]u32 {
    var rect: RECT = undefined;
    if (!GetClientRect(hwnd, &rect).toBool()) return null;
    return rectSize(rect);
}

fn rectSize(rect: RECT) [2]u32 {
    return .{
        @intCast(@max(0, rect.right - rect.left)),
        @intCast(@max(0, rect.bottom - rect.top)),
    };
}

fn scaleForDpi(value: c_int, dpi: windows.UINT) !c_int {
    if (value <= 0 or dpi == 0) return error.InvalidWindowSize;
    const scaled = @divTrunc(
        @as(i64, value) * @as(i64, dpi) + @divTrunc(Win32.Dpi.base, 2),
        @as(i64, Win32.Dpi.base),
    );
    return std.math.cast(c_int, @max(scaled, 1)) orelse error.InvalidWindowSize;
}

fn ptrFromLparam(comptime T: type, value: windows.LPARAM) *const T {
    return @ptrFromInt(@as(usize, @bitCast(value)));
}

fn clientPointFromLparam(value: windows.LPARAM) [2]f64 {
    return .{
        @floatFromInt(signedLowWord(value)),
        @floatFromInt(signedHighWord(value)),
    };
}

fn screenPointToClient(hwnd: windows.HWND, value: windows.LPARAM) ?[2]f64 {
    var point = POINT{
        .x = signedLowWord(value),
        .y = signedHighWord(value),
    };
    if (!ScreenToClient(hwnd, &point).toBool()) return null;
    return .{
        @floatFromInt(point.x),
        @floatFromInt(point.y),
    };
}

fn lowWord(value: windows.LPARAM) u16 {
    return @truncate(@as(usize, @bitCast(value)));
}

fn highWord(value: windows.LPARAM) u16 {
    return @truncate(@as(usize, @bitCast(value)) >> 16);
}

fn signedLowWord(value: windows.LPARAM) i16 {
    return @bitCast(lowWord(value));
}

fn signedHighWord(value: windows.LPARAM) i16 {
    return @bitCast(highWord(value));
}

fn highWordU(value: WPARAM) u16 {
    return @truncate(value >> 16);
}

fn signedHighWordU(value: WPARAM) i16 {
    return @bitCast(highWordU(value));
}

fn dpiFromWparam(value: WPARAM) windows.UINT {
    const dpi_x: windows.UINT = @intCast(@as(u16, @truncate(value)));
    const dpi_y: windows.UINT = @intCast(highWordU(value));
    return if (dpi_x != 0) dpi_x else if (dpi_y != 0) dpi_y else Win32.Dpi.base;
}

fn dpiScale(dpi: windows.UINT) f64 {
    if (dpi == 0) return 1.0;
    return @as(f64, @floatFromInt(dpi)) / @as(f64, @floatFromInt(Win32.Dpi.base));
}

fn wheelDeltaFromWparam(value: WPARAM) f64 {
    return @as(f64, @floatFromInt(signedHighWordU(value))) / Win32.wheel_delta;
}

fn queryPerformanceCounter() !i64 {
    var counter: windows.LARGE_INTEGER = 0;
    if (!ntdll.RtlQueryPerformanceCounter(&counter).toBool()) return error.PerformanceCounterUnavailable;
    return counter;
}

fn queryPerformanceFrequency() !i64 {
    var frequency: windows.LARGE_INTEGER = 0;
    if (!ntdll.RtlQueryPerformanceFrequency(&frequency).toBool() or frequency <= 0) {
        return error.PerformanceCounterUnavailable;
    }
    return frequency;
}

test "Win32 style keeps the native title bar and system commands" {
    try std.testing.expect(Win32.Style.standard_titled_window & Win32.Style.caption != 0);
    try std.testing.expect(Win32.Style.standard_titled_window & Win32.Style.sysmenu != 0);
    try std.testing.expect(Win32.Style.standard_titled_window & Win32.Style.thickframe != 0);
}

test "Win32 title encoding preserves Unicode and rejects sentinel truncation" {
    const title = try demo_title.allocUtf16LeZ(std.testing.allocator, "heavy-slug 日本語");
    defer std.testing.allocator.free(title);

    try std.testing.expectEqual(@as(u16, 0), title[title.len]);
    try std.testing.expect(std.mem.indexOfScalar(u16, title, 0) == null);
    try std.testing.expectError(error.InvalidWindowTitle, demo_title.allocUtf16LeZ(std.testing.allocator, "heavy\x00slug"));
}

test "Win32 DPI scaling follows positive MulDiv-style rounding" {
    try std.testing.expectEqual(@as(c_int, 960), try scaleForDpi(960, 96));
    try std.testing.expectEqual(@as(c_int, 1200), try scaleForDpi(960, 120));
    try std.testing.expectEqual(@as(c_int, 128), try scaleForDpi(102, 120));
    try std.testing.expectError(error.InvalidWindowSize, scaleForDpi(0, 96));
    try std.testing.expectError(error.InvalidWindowSize, scaleForDpi(1280, 0));
}

test "Win32 word helpers preserve signed mouse coordinates and wheel deltas" {
    const lparam = makeLparamWords(@bitCast(@as(i16, -32)), @bitCast(@as(i16, 48)));
    try std.testing.expectEqual(@as(i16, -32), signedLowWord(lparam));
    try std.testing.expectEqual(@as(i16, 48), signedHighWord(lparam));
    try std.testing.expectEqual(@as([2]f64, .{ -32, 48 }), clientPointFromLparam(lparam));

    const wparam = makeWparamWords(0, @bitCast(@as(i16, -120)));
    try std.testing.expectEqual(@as(i16, -120), signedHighWordU(wparam));
    try std.testing.expectEqual(@as(f64, -1), wheelDeltaFromWparam(wparam));
}

test "Win32 DPI and rect helpers normalize platform packed values" {
    try std.testing.expectEqual(@as(windows.UINT, 144), dpiFromWparam(makeWparamWords(144, 144)));
    try std.testing.expectEqual(@as(windows.UINT, 168), dpiFromWparam(makeWparamWords(0, 168)));
    try std.testing.expectEqual(@as(windows.UINT, Win32.Dpi.base), dpiFromWparam(0));
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), dpiScale(144), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), dpiScale(0), 1.0e-12);

    try std.testing.expectEqual(@as([2]u32, .{ 640, 480 }), rectSize(.{
        .left = 20,
        .top = 10,
        .right = 660,
        .bottom = 490,
    }));
    try std.testing.expectEqual(@as([2]u32, .{ 0, 0 }), rectSize(.{
        .left = 10,
        .top = 10,
        .right = 5,
        .bottom = 8,
    }));
}

test "Win32 DWM chrome helpers encode COLORREF palettes" {
    try std.testing.expectEqual(@as(windows.COLORREF, 0x00332211), rgb(0x11, 0x22, 0x33));
    try std.testing.expectEqual(ChromeTheme.light, chromeThemeFromDarkMode(false));
    try std.testing.expectEqual(ChromeTheme.dark, chromeThemeFromDarkMode(true));

    const light = chromePalette(.light);
    const dark = chromePalette(.dark);
    try std.testing.expect(light.caption != dark.caption);
    try std.testing.expect(light.text != dark.text);
}

test "Win32 native user table resolves Windows 11 direct NtUser entry points" {
    try std.testing.expectEqualStrings("NtUserDestroyWindow", NativeUser.procedureName(.destroy_window));
    try std.testing.expectEqualStrings("NtUserReleaseCapture", NativeUser.procedureName(.release_capture));
    try std.testing.expectEqualStrings("NtUserSetCapture", NativeUser.procedureName(.set_capture));
    try std.testing.expectEqualStrings("NtUserSetWindowPos", NativeUser.procedureName(.set_window_pos));
    try std.testing.expectEqualStrings("NtUserShowWindow", NativeUser.procedureName(.show_window));
}

test "Win32 surface capabilities keep zero-copy present on Vulkan WSI" {
    const window: Window = .{};
    const caps = window.surfaceCapabilities();
    try std.testing.expect(caps.supportsDirectSwapchain());
    try std.testing.expectEqual(SurfaceCapabilities.ExternalMemory.not_used_for_vulkan_wsi, caps.external_memory);
    try std.testing.expectEqual(SurfaceCapabilities.SharedSection.not_used_for_vulkan_wsi, caps.shared_section);
}

fn makeLparamWords(low: u16, high: u16) windows.LPARAM {
    const bits = @as(usize, low) | (@as(usize, high) << 16);
    return @as(windows.LPARAM, @bitCast(bits));
}

fn makeWparamWords(low: u16, high: u16) WPARAM {
    return @as(usize, low) | (@as(usize, high) << 16);
}
