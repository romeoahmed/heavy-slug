//! Win32 demo window, input, and Vulkan surface glue.

const std = @import("std");
const windows = std.os.windows;
const vk = @import("vulkan");
const demo_input = @import("demo_input");

const WPARAM = usize;
const LRESULT = isize;
const HRESULT = windows.LONG;

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

extern "kernel32" fn GetModuleHandleW(lpModuleName: ?windows.LPCWSTR) callconv(.winapi) ?windows.HMODULE;
extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: windows.LPCSTR) callconv(.winapi) ?windows.FARPROC;
extern "kernel32" fn LoadLibraryW(lpLibFileName: windows.LPCWSTR) callconv(.winapi) ?windows.HMODULE;
extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *windows.LARGE_INTEGER) callconv(.winapi) windows.BOOL;
extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *windows.LARGE_INTEGER) callconv(.winapi) windows.BOOL;

extern "user32" fn AdjustWindowRectExForDpi(lpRect: *RECT, dwStyle: windows.DWORD, bMenu: windows.BOOL, dwExStyle: windows.DWORD, dpi: windows.UINT) callconv(.winapi) windows.BOOL;
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
extern "user32" fn DefWindowProcW(hwnd: windows.HWND, msg: windows.UINT, wparam: WPARAM, lparam: windows.LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn DestroyWindow(hWnd: windows.HWND) callconv(.winapi) windows.BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn GetClientRect(hWnd: windows.HWND, lpRect: *RECT) callconv(.winapi) windows.BOOL;
extern "user32" fn GetDpiForWindow(hwnd: windows.HWND) callconv(.winapi) windows.UINT;
extern "user32" fn GetWindowLongPtrW(hWnd: windows.HWND, nIndex: c_int) callconv(.winapi) windows.LONG_PTR;
extern "user32" fn LoadCursorW(hInstance: ?windows.HINSTANCE, lpCursorName: windows.LPCWSTR) callconv(.winapi) ?windows.HCURSOR;
extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?windows.HWND, wMsgFilterMin: windows.UINT, wMsgFilterMax: windows.UINT, wRemoveMsg: windows.UINT) callconv(.winapi) windows.BOOL;
extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) windows.ATOM;
extern "user32" fn ReleaseCapture() callconv(.winapi) windows.BOOL;
extern "user32" fn SetCapture(hWnd: windows.HWND) callconv(.winapi) ?windows.HWND;
extern "user32" fn SetProcessDpiAwarenessContext(value: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "user32" fn SetWindowLongPtrW(hWnd: windows.HWND, nIndex: c_int, dwNewLong: windows.LONG_PTR) callconv(.winapi) windows.LONG_PTR;
extern "user32" fn SetWindowPos(hWnd: windows.HWND, hWndInsertAfter: ?windows.HWND, X: c_int, Y: c_int, cx: c_int, cy: c_int, uFlags: windows.UINT) callconv(.winapi) windows.BOOL;
extern "user32" fn ShowWindow(hWnd: windows.HWND, nCmdShow: c_int) callconv(.winapi) windows.BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) windows.BOOL;

const win32 = struct {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("HeavySlugDemoWindow");

    const module = struct {
        const dwmapi = std.unicode.utf8ToUtf16LeStringLiteral("dwmapi.dll");
        const vulkan_loader = std.unicode.utf8ToUtf16LeStringLiteral("vulkan-1.dll");
    };

    const dpi = struct {
        const default_screen: windows.UINT = 96;
        const per_monitor_v2: windows.HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));
    };

    const dwm = struct {
        const use_immersive_dark_mode: windows.DWORD = 20;
    };

    const error_code = struct {
        const class_already_exists = windows.Win32Error.CLASS_ALREADY_EXISTS;
    };

    const pointer = struct {
        const arrow: windows.LPCWSTR = @ptrFromInt(32512);
    };

    const message = struct {
        const destroy = 0x0002;
        const size = 0x0005;
        const kill_focus = 0x0008;
        const close = 0x0010;
        const erase_background = 0x0014;
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

    const peek = struct {
        const remove = 0x0001;
    };

    const show = struct {
        const show = 5;
    };

    const style = struct {
        const overlapped_window: windows.DWORD = 0x00CF0000;
    };

    const set_window_pos = struct {
        const no_move = 0x0002;
        const no_z_order = 0x0004;
        const no_activate = 0x0010;
    };

    const window_long = struct {
        const user_data = -21;
    };

    const virtual_key = struct {
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

    const wheel_delta = 120.0;
    const use_default_position = std.math.minInt(c_int);
};

const required_instance_extensions = [_][*:0]const u8{
    "VK_KHR_surface",
    "VK_KHR_win32_surface",
};

var vulkan_loader: ?windows.HMODULE = null;
var vk_get_instance_proc_addr: ?vk.PfnGetInstanceProcAddr = null;
var dwmapi: ?windows.HMODULE = null;
var dwm_set_window_attribute: ?DwmSetWindowAttributeFn = null;
var dwm_dark_mode_available = true;

pub const Window = struct {
    hwnd: windows.HWND = undefined,
    hinstance: windows.HINSTANCE = undefined,
    input_state: demo_input.State = .{},
    framebuffer_width: u32 = 0,
    framebuffer_height: u32 = 0,
    should_close: bool = false,
    dark_titlebar: ?bool = null,
    qpc_frequency: i64 = 0,
    qpc_start: i64 = 0,

    pub fn init(self: *Window, allocator: std.mem.Allocator, width: c_int, height: c_int, title: []const u8) !void {
        enablePerMonitorDpiFallback();
        try loadVulkanLoader();

        const hmodule = GetModuleHandleW(null) orelse return error.ModuleHandleUnavailable;
        const hinstance: windows.HINSTANCE = @ptrCast(hmodule);
        try registerClass(hinstance);

        const qpc_frequency = try queryPerformanceFrequency();
        const qpc_start = try queryPerformanceCounter();
        self.* = .{
            .hinstance = hinstance,
            .qpc_frequency = qpc_frequency,
            .qpc_start = qpc_start,
        };

        const title_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, title);
        defer allocator.free(title_w);

        const hwnd = CreateWindowExW(
            0,
            win32.class_name,
            title_w.ptr,
            win32.style.overlapped_window,
            win32.use_default_position,
            win32.use_default_position,
            win32.use_default_position,
            win32.use_default_position,
            null,
            null,
            hinstance,
            self,
        ) orelse return error.WindowCreationFailed;
        errdefer _ = DestroyWindow(hwnd);

        self.hwnd = hwnd;
        _ = SetWindowLongPtrW(hwnd, win32.window_long.user_data, windowPtrToLong(self));

        try self.resizeLogicalClientArea(width, height);
        self.refreshFramebufferSize();
        self.setDarkMode(false);
        _ = ShowWindow(hwnd, win32.show.show);
    }

    pub fn deinit(self: *Window) void {
        _ = SetWindowLongPtrW(self.hwnd, win32.window_long.user_data, 0);
        _ = DestroyWindow(self.hwnd);
    }

    pub fn pollEvents(self: *Window) void {
        var msg: MSG = undefined;
        while (PeekMessageW(&msg, null, 0, 0, win32.peek.remove).toBool()) {
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

    pub fn time(self: *const Window) f64 {
        const now = queryPerformanceCounter() catch self.qpc_start;
        return @as(f64, @floatFromInt(now - self.qpc_start)) /
            @as(f64, @floatFromInt(self.qpc_frequency));
    }

    pub fn setDarkMode(self: *Window, enabled: bool) void {
        if (!dwm_dark_mode_available) return;
        if (self.dark_titlebar != null and self.dark_titlebar.? == enabled) return;

        const set_window_attribute = loadDwmSetWindowAttribute() orelse {
            dwm_dark_mode_available = false;
            return;
        };

        var value = windows.BOOL.fromBool(enabled);
        const hr = set_window_attribute(
            self.hwnd,
            win32.dwm.use_immersive_dark_mode,
            @ptrCast(&value),
            @sizeOf(windows.BOOL),
        );
        if (hr < 0) {
            dwm_dark_mode_available = false;
            return;
        }
        self.dark_titlebar = enabled;
    }

    pub fn createSurface(self: *const Window, instance: vk.Instance, idisp: anytype) !vk.SurfaceKHR {
        const create_info = vk.Win32SurfaceCreateInfoKHR{
            .hinstance = self.hinstance,
            .hwnd = self.hwnd,
        };
        return idisp.createWin32SurfaceKHR(instance, &create_info, null) catch error.SurfaceCreationFailed;
    }

    fn refreshFramebufferSize(self: *Window) void {
        self.framebuffer_width, self.framebuffer_height = clientSize(self.hwnd) orelse return;
    }

    fn resizeLogicalClientArea(self: *Window, width: c_int, height: c_int) !void {
        const dpi = GetDpiForWindow(self.hwnd);
        var rect = RECT{
            .left = 0,
            .top = 0,
            .right = try scaleForDpi(width, dpi),
            .bottom = try scaleForDpi(height, dpi),
        };
        if (!AdjustWindowRectExForDpi(&rect, win32.style.overlapped_window, .FALSE, 0, dpi).toBool()) {
            return error.WindowRectFailed;
        }
        if (!SetWindowPos(
            self.hwnd,
            null,
            0,
            0,
            rect.right - rect.left,
            rect.bottom - rect.top,
            win32.set_window_pos.no_move | win32.set_window_pos.no_z_order | win32.set_window_pos.no_activate,
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

fn enablePerMonitorDpiFallback() void {
    if (SetProcessDpiAwarenessContext(win32.dpi.per_monitor_v2).toBool()) return;
    _ = windows.GetLastError();
}

fn loadVulkanLoader() !void {
    if (vk_get_instance_proc_addr != null) return;

    const loader = LoadLibraryW(win32.module.vulkan_loader) orelse return error.VulkanLoaderUnavailable;
    const proc = GetProcAddress(loader, "vkGetInstanceProcAddr") orelse return error.VulkanLoaderUnavailable;
    vulkan_loader = loader;
    vk_get_instance_proc_addr = @ptrCast(proc);
}

fn loadDwmSetWindowAttribute() ?DwmSetWindowAttributeFn {
    if (dwm_set_window_attribute) |proc| return proc;

    const module = LoadLibraryW(win32.module.dwmapi) orelse return null;
    const proc = GetProcAddress(module, "DwmSetWindowAttribute") orelse return null;
    dwmapi = module;
    dwm_set_window_attribute = @ptrCast(proc);
    return dwm_set_window_attribute;
}

fn registerClass(hinstance: windows.HINSTANCE) !void {
    const cls = WNDCLASSEXW{
        .style = 0,
        .lpfnWndProc = windowProc,
        .hInstance = hinstance,
        .hCursor = LoadCursorW(null, win32.pointer.arrow),
        .lpszClassName = win32.class_name,
    };
    if (RegisterClassExW(&cls) == 0 and windows.GetLastError() != win32.error_code.class_already_exists) {
        return error.WindowClassRegistrationFailed;
    }
}

fn windowProc(hwnd: windows.HWND, msg: windows.UINT, wparam: WPARAM, lparam: windows.LPARAM) callconv(.winapi) LRESULT {
    if (msg == win32.message.nccreate) {
        const create: *const CREATESTRUCTW = ptrFromLparam(CREATESTRUCTW, lparam);
        if (create.lpCreateParams) |param| {
            const window: *Window = @ptrCast(@alignCast(param));
            window.hwnd = hwnd;
            _ = SetWindowLongPtrW(hwnd, win32.window_long.user_data, windowPtrToLong(window));
            window.refreshFramebufferSize();
            return 1;
        }
        return 0;
    }

    const maybe_window = windowFromHwnd(hwnd);
    switch (msg) {
        win32.message.close => {
            if (maybe_window) |window| window.should_close = true;
            return 0;
        },
        win32.message.destroy => {
            if (maybe_window) |window| window.should_close = true;
            return 0;
        },
        win32.message.ncdestroy => {
            _ = SetWindowLongPtrW(hwnd, win32.window_long.user_data, 0);
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.message.erase_background => return 1,
        win32.message.dpi_changed => {
            const suggested: *const RECT = ptrFromLparam(RECT, lparam);
            _ = SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                win32.set_window_pos.no_z_order | win32.set_window_pos.no_activate,
            );
            if (maybe_window) |window| window.refreshFramebufferSize();
            return 0;
        },
        win32.message.size => {
            if (maybe_window) |window| {
                window.framebuffer_width = lowWord(lparam);
                window.framebuffer_height = highWord(lparam);
            }
            return 0;
        },
        win32.message.kill_focus, win32.message.cancel_mode => {
            if (maybe_window) |window| {
                window.input_state.clearKeys();
                window.input_state.clearMouseButtons();
            }
            _ = ReleaseCapture();
            return 0;
        },
        win32.message.key_down, win32.message.sys_key_down => {
            if (maybe_window) |window| {
                if (mapKey(wparam)) |key| {
                    window.input_state.setKey(key, true);
                    return 0;
                }
            }
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.message.key_up, win32.message.sys_key_up => {
            if (maybe_window) |window| {
                if (mapKey(wparam)) |key| {
                    window.input_state.setKey(key, false);
                    return 0;
                }
            }
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.message.left_button_down => {
            if (maybe_window) |window| window.input_state.setMouseButton(.left, true);
            _ = SetCapture(hwnd);
            return 0;
        },
        win32.message.left_button_up => {
            if (maybe_window) |window| {
                window.input_state.setMouseButton(.left, false);
                updateCapture(hwnd, window);
            }
            return 0;
        },
        win32.message.right_button_down => {
            if (maybe_window) |window| window.input_state.setMouseButton(.right, true);
            _ = SetCapture(hwnd);
            return 0;
        },
        win32.message.right_button_up => {
            if (maybe_window) |window| {
                window.input_state.setMouseButton(.right, false);
                updateCapture(hwnd, window);
            }
            return 0;
        },
        win32.message.capture_changed => {
            if (maybe_window) |window| {
                window.input_state.clearMouseButtons();
            }
            return 0;
        },
        win32.message.mouse_move => {
            if (maybe_window) |window| {
                window.input_state.setCursor(
                    @floatFromInt(signedLowWord(lparam)),
                    @floatFromInt(signedHighWord(lparam)),
                );
            }
            return 0;
        },
        win32.message.mouse_wheel => {
            if (maybe_window) |window| {
                window.input_state.addScroll(@as(f64, @floatFromInt(signedHighWordU(wparam))) / win32.wheel_delta);
            }
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn updateCapture(hwnd: windows.HWND, window: *Window) void {
    if (window.input_state.getMouseButton(.left) or window.input_state.getMouseButton(.right)) {
        _ = SetCapture(hwnd);
    } else {
        _ = ReleaseCapture();
    }
}

fn windowFromHwnd(hwnd: windows.HWND) ?*Window {
    const ptr_value = GetWindowLongPtrW(hwnd, win32.window_long.user_data);
    if (ptr_value == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr_value)));
}

fn windowPtrToLong(window: *Window) windows.LONG_PTR {
    return @as(windows.LONG_PTR, @bitCast(@intFromPtr(window)));
}

fn mapKey(wparam: WPARAM) ?demo_input.Key {
    return switch (wparam) {
        win32.virtual_key.escape => .escape,
        win32.virtual_key.space => .space,
        win32.virtual_key.oem_plus, win32.virtual_key.add => .equal,
        win32.virtual_key.oem_minus, win32.virtual_key.subtract => .minus,
        win32.virtual_key.b => .b,
        win32.virtual_key.r => .r,
        win32.virtual_key.up => .up,
        win32.virtual_key.down => .down,
        win32.virtual_key.left => .left,
        win32.virtual_key.right => .right,
        else => null,
    };
}

fn clientSize(hwnd: windows.HWND) ?[2]u32 {
    var rect: RECT = undefined;
    if (!GetClientRect(hwnd, &rect).toBool()) return null;
    return .{
        @intCast(@max(0, rect.right - rect.left)),
        @intCast(@max(0, rect.bottom - rect.top)),
    };
}

fn scaleForDpi(value: c_int, dpi: windows.UINT) !c_int {
    if (value <= 0 or dpi == 0) return error.InvalidWindowSize;
    const scaled = @divTrunc(
        @as(i64, value) * @as(i64, dpi) + @divTrunc(win32.dpi.default_screen, 2),
        @as(i64, win32.dpi.default_screen),
    );
    return std.math.cast(c_int, @max(scaled, 1)) orelse error.InvalidWindowSize;
}

fn ptrFromLparam(comptime T: type, value: windows.LPARAM) *const T {
    return @ptrFromInt(@as(usize, @bitCast(value)));
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

fn signedHighWordU(value: WPARAM) i16 {
    return @bitCast(@as(u16, @truncate(value >> 16)));
}

fn queryPerformanceCounter() !i64 {
    var counter: windows.LARGE_INTEGER = 0;
    if (!QueryPerformanceCounter(&counter).toBool()) return error.PerformanceCounterUnavailable;
    return counter;
}

fn queryPerformanceFrequency() !i64 {
    var frequency: windows.LARGE_INTEGER = 0;
    if (!QueryPerformanceFrequency(&frequency).toBool() or frequency <= 0) {
        return error.PerformanceCounterUnavailable;
    }
    return frequency;
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

    const wparam = makeWparamWords(0, @bitCast(@as(i16, -120)));
    try std.testing.expectEqual(@as(i16, -120), signedHighWordU(wparam));
}

fn makeLparamWords(low: u16, high: u16) windows.LPARAM {
    const bits = @as(usize, low) | (@as(usize, high) << 16);
    return @as(windows.LPARAM, @bitCast(bits));
}

fn makeWparamWords(low: u16, high: u16) WPARAM {
    return @as(usize, low) | (@as(usize, high) << 16);
}
