//! Win32 demo window and Vulkan surface glue.

const std = @import("std");
const windows = std.os.windows;
const vk = @import("vulkan");
const demo_input = @import("demo_input");

const WndProc = *const fn (hwnd: windows.HWND, msg: windows.UINT, wparam: WPARAM, lparam: windows.LPARAM) callconv(.winapi) LRESULT;
const DwmSetWindowAttributeFn = *const fn (hwnd: windows.HWND, dwAttribute: windows.DWORD, pvAttribute: windows.LPCVOID, cbAttribute: windows.DWORD) callconv(.winapi) HRESULT;
const WPARAM = usize;
const LRESULT = isize;
const HRESULT = windows.LONG;

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

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("HeavySlugDemoWindow");
const dwmapi_name = std.unicode.utf8ToUtf16LeStringLiteral("dwmapi.dll");
const vulkan_loader_name = std.unicode.utf8ToUtf16LeStringLiteral("vulkan-1.dll");
const required_instance_extensions = [_][*:0]const u8{
    "VK_KHR_surface",
    "VK_KHR_win32_surface",
};

var vulkan_loader: ?windows.HMODULE = null;
var vk_get_instance_proc_addr: ?vk.PfnGetInstanceProcAddr = null;
var dwmapi: ?windows.HMODULE = null;
var dwm_set_window_attribute: ?DwmSetWindowAttributeFn = null;

const ERROR_CLASS_ALREADY_EXISTS = windows.Win32Error.CLASS_ALREADY_EXISTS;
const CW_USEDEFAULT = std.math.minInt(c_int);
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: windows.HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));
const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
const GWLP_USERDATA = -21;
const IDC_ARROW: windows.LPCWSTR = @ptrFromInt(32512);
const PM_REMOVE = 0x0001;
const USER_DEFAULT_SCREEN_DPI = 96;
const SW_SHOW = 5;
const SWP_NOMOVE = 0x0002;
const SWP_NOZORDER = 0x0004;
const SWP_NOACTIVATE = 0x0010;
const WHEEL_DELTA = 120.0;

const WM_CLOSE = 0x0010;
const WM_DESTROY = 0x0002;
const WM_ERASEBKGND = 0x0014;
const WM_NCDESTROY = 0x0082;
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;
const WM_LBUTTONDOWN = 0x0201;
const WM_LBUTTONUP = 0x0202;
const WM_MOUSEMOVE = 0x0200;
const WM_MOUSEWHEEL = 0x020A;
const WM_RBUTTONDOWN = 0x0204;
const WM_RBUTTONUP = 0x0205;
const WM_SIZE = 0x0005;
const WM_CAPTURECHANGED = 0x0215;
const WM_DPICHANGED = 0x02E0;
const WM_SYSKEYDOWN = 0x0104;
const WM_SYSKEYUP = 0x0105;

const WS_OVERLAPPEDWINDOW = 0x00CF0000;

const VK_ESCAPE = 0x1B;
const VK_SPACE = 0x20;
const VK_LEFT = 0x25;
const VK_UP = 0x26;
const VK_RIGHT = 0x27;
const VK_DOWN = 0x28;
const VK_B = 0x42;
const VK_R = 0x52;
const VK_OEM_MINUS = 0xBD;
const VK_OEM_PLUS = 0xBB;
const VK_SUBTRACT = 0x6D;
const VK_ADD = 0x6B;

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
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        try loadVulkanLoader();

        const hmodule = GetModuleHandleW(null) orelse return error.ModuleHandleUnavailable;
        const hinstance: windows.HINSTANCE = @ptrCast(hmodule);
        try registerClass(hinstance);

        const title_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, title);
        defer allocator.free(title_w);

        const hwnd = CreateWindowExW(
            0,
            class_name,
            title_w.ptr,
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            null,
            null,
            hinstance,
            null,
        ) orelse return error.WindowCreationFailed;
        errdefer _ = DestroyWindow(hwnd);

        const qpc_frequency = try queryPerformanceFrequency();
        const qpc_start = try queryPerformanceCounter();

        self.* = .{
            .hwnd = hwnd,
            .hinstance = hinstance,
            .qpc_frequency = qpc_frequency,
            .qpc_start = qpc_start,
        };
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @intCast(@intFromPtr(self)));
        try self.resizeLogicalClientArea(width, height);
        self.refreshFramebufferSize();
        self.setDarkMode(false);
        _ = ShowWindow(hwnd, SW_SHOW);
    }

    pub fn deinit(self: *Window) void {
        _ = SetWindowLongPtrW(self.hwnd, GWLP_USERDATA, 0);
        _ = DestroyWindow(self.hwnd);
    }

    pub fn pollEvents(self: *Window) void {
        var msg: MSG = undefined;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE).toBool()) {
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
        if (self.dark_titlebar != null and self.dark_titlebar.? == enabled) return;
        self.dark_titlebar = enabled;

        const set_window_attribute = loadDwmSetWindowAttribute() orelse return;
        var value = windows.BOOL.fromBool(enabled);
        _ = set_window_attribute(
            self.hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE,
            @ptrCast(&value),
            @sizeOf(windows.BOOL),
        );
    }

    pub fn createSurface(self: *const Window, instance: vk.Instance, idisp: anytype) !vk.SurfaceKHR {
        const create_info = vk.Win32SurfaceCreateInfoKHR{
            .hinstance = self.hinstance,
            .hwnd = self.hwnd,
        };
        return idisp.createWin32SurfaceKHR(instance, &create_info, null) catch error.SurfaceCreationFailed;
    }

    fn refreshFramebufferSize(self: *Window) void {
        var rect: RECT = undefined;
        if (!GetClientRect(self.hwnd, &rect).toBool()) return;
        self.framebuffer_width = @intCast(@max(0, rect.right - rect.left));
        self.framebuffer_height = @intCast(@max(0, rect.bottom - rect.top));
    }

    fn resizeLogicalClientArea(self: *Window, width: c_int, height: c_int) !void {
        const dpi = GetDpiForWindow(self.hwnd);
        var rect = RECT{
            .left = 0,
            .top = 0,
            .right = try logicalPixelsForDpi(width, dpi),
            .bottom = try logicalPixelsForDpi(height, dpi),
        };
        if (!AdjustWindowRectExForDpi(&rect, WS_OVERLAPPEDWINDOW, .FALSE, 0, dpi).toBool()) {
            return error.WindowRectFailed;
        }
        if (!SetWindowPos(
            self.hwnd,
            null,
            0,
            0,
            rect.right - rect.left,
            rect.bottom - rect.top,
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE,
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

fn loadVulkanLoader() !void {
    if (vk_get_instance_proc_addr != null) return;

    const loader = LoadLibraryW(vulkan_loader_name) orelse return error.VulkanLoaderUnavailable;
    const proc = GetProcAddress(loader, "vkGetInstanceProcAddr") orelse return error.VulkanLoaderUnavailable;
    vulkan_loader = loader;
    vk_get_instance_proc_addr = @ptrCast(proc);
}

fn loadDwmSetWindowAttribute() ?DwmSetWindowAttributeFn {
    if (dwm_set_window_attribute) |proc| return proc;

    const module = LoadLibraryW(dwmapi_name) orelse return null;
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
        .hCursor = LoadCursorW(null, IDC_ARROW),
        .lpszClassName = class_name,
    };
    if (RegisterClassExW(&cls) == 0 and windows.GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        return error.WindowClassRegistrationFailed;
    }
}

fn windowProc(hwnd: windows.HWND, msg: windows.UINT, wparam: WPARAM, lparam: windows.LPARAM) callconv(.winapi) LRESULT {
    const maybe_window = windowFromHwnd(hwnd);
    switch (msg) {
        WM_CLOSE => {
            if (maybe_window) |window| window.should_close = true;
            return 0;
        },
        WM_DESTROY => return 0,
        WM_NCDESTROY => {
            _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_ERASEBKGND => return 1,
        WM_DPICHANGED => {
            const suggested: *const RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
            if (maybe_window) |window| window.refreshFramebufferSize();
            return 0;
        },
        WM_SIZE => {
            if (maybe_window) |window| {
                window.framebuffer_width = @intCast(lowWord(lparam));
                window.framebuffer_height = @intCast(highWord(lparam));
            }
            return 0;
        },
        WM_KEYDOWN, WM_SYSKEYDOWN => {
            if (maybe_window) |window| {
                if (mapKey(wparam)) |key| {
                    window.input_state.setKey(key, true);
                    return 0;
                }
            }
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_KEYUP, WM_SYSKEYUP => {
            if (maybe_window) |window| {
                if (mapKey(wparam)) |key| {
                    window.input_state.setKey(key, false);
                    return 0;
                }
            }
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_LBUTTONDOWN => {
            if (maybe_window) |window| window.input_state.setMouseButton(.left, true);
            _ = SetCapture(hwnd);
            return 0;
        },
        WM_LBUTTONUP => {
            if (maybe_window) |window| {
                window.input_state.setMouseButton(.left, false);
                updateCapture(hwnd, window);
            }
            return 0;
        },
        WM_RBUTTONDOWN => {
            if (maybe_window) |window| window.input_state.setMouseButton(.right, true);
            _ = SetCapture(hwnd);
            return 0;
        },
        WM_RBUTTONUP => {
            if (maybe_window) |window| {
                window.input_state.setMouseButton(.right, false);
                updateCapture(hwnd, window);
            }
            return 0;
        },
        WM_CAPTURECHANGED => {
            if (maybe_window) |window| {
                window.input_state.setMouseButton(.left, false);
                window.input_state.setMouseButton(.right, false);
            }
            return 0;
        },
        WM_MOUSEMOVE => {
            if (maybe_window) |window| {
                window.input_state.setCursor(
                    @floatFromInt(signedLowWord(lparam)),
                    @floatFromInt(signedHighWord(lparam)),
                );
            }
            return 0;
        },
        WM_MOUSEWHEEL => {
            if (maybe_window) |window| {
                window.input_state.addScroll(@as(f64, @floatFromInt(signedHighWordU(wparam))) / WHEEL_DELTA);
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
    const ptr_value = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (ptr_value == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(ptr_value)));
}

fn mapKey(wparam: WPARAM) ?demo_input.Key {
    return switch (wparam) {
        VK_ESCAPE => .escape,
        VK_SPACE => .space,
        VK_OEM_PLUS, VK_ADD => .equal,
        VK_OEM_MINUS, VK_SUBTRACT => .minus,
        VK_B => .b,
        VK_R => .r,
        VK_UP => .up,
        VK_DOWN => .down,
        VK_LEFT => .left,
        VK_RIGHT => .right,
        else => null,
    };
}

fn logicalPixelsForDpi(value: c_int, dpi: windows.UINT) !c_int {
    if (value <= 0 or dpi == 0) return error.InvalidWindowSize;
    const scaled = @divTrunc(
        @as(i64, value) * @as(i64, dpi),
        @as(i64, USER_DEFAULT_SCREEN_DPI),
    );
    return std.math.cast(c_int, @max(scaled, 1)) orelse error.InvalidWindowSize;
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
