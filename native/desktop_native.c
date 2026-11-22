/* Minimal Godot C ABI bridge. The Godot interface header retains its MIT notice. */
#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "include/gdextension_interface.h"

typedef struct {
    GDExtensionObjectPtr object;
    HWND hwnd;
    LONG_PTR previous_style;
    HANDLE singleton;
    int attached;
    uint64_t suspend_callback[3];
    int has_suspend_callback;
    uint64_t action_callback[3];
    int has_action_callback;
    HWND shell_hwnd;
    HICON tray_icon;
    int tray_registered;
    int hotkey_registered;
    int test_namespace;
    int shell_flags;
    DWORD shell_error;
} DesktopState;

#define FARM_TRAY_MESSAGE (WM_APP + 61)
#define FARM_HOTKEY_ID 0xDF17
#define FARM_MENU_BASE 0xD100
static UINT taskbar_created;
static const wchar_t shell_class[] = L"DesktopFarm.NativeShell.v07";
static void shutdown_shell(DesktopState *state);
static int install_tray(DesktopState *state);

static volatile LONG suspended = 0;
static volatile LONG power_epoch = 0;
static volatile LONG suspend_epoch = 0;
static GDExtensionClassLibraryPtr library;
static uint64_t class_name, parent_name, empty_name, empty_string, callable_call_name;
static GDExtensionInterfaceStringNameNewWithUtf8Chars sn_new;
static GDExtensionInterfaceStringNewWithUtf8Chars str_new;
static GDExtensionInterfaceClassdbConstructObject2 construct_object;
static GDExtensionInterfaceClassdbGetMethodBind get_method_bind;
static GDExtensionInterfaceObjectMethodBindPtrcall object_ptrcall;
static GDExtensionMethodBindPtr postinitialize;
static GDExtensionInterfaceObjectSetInstance object_set_instance;
static GDExtensionInterfaceClassdbRegisterExtensionClass4 register_class;
static GDExtensionInterfaceClassdbRegisterExtensionClassMethod register_method;
static GDExtensionInterfaceClassdbUnregisterExtensionClass unregister_class;
static GDExtensionInterfaceVariantNewNil variant_nil;
static GDExtensionInterfaceVariantNewCopy variant_copy;
static GDExtensionInterfaceVariantDestroy variant_destroy;
static GDExtensionInterfaceVariantCall variant_call;
static GDExtensionInterfaceVariantGetType variant_type;
static GDExtensionVariantFromTypeConstructorFunc from_type[GDEXTENSION_VARIANT_TYPE_VARIANT_MAX];
static GDExtensionTypeFromVariantConstructorFunc to_type[GDEXTENSION_VARIANT_TYPE_VARIANT_MAX];
static GDExtensionPtrDestructor sn_destroy, str_destroy;

static void emit_action(DesktopState *state, int action) {
    if (!state->has_action_callback) return;
    int64_t value = action;
    uint64_t argument[3], ret[3];
    GDExtensionCallError error;
    from_type[GDEXTENSION_VARIANT_TYPE_INT](argument, &value);
    const GDExtensionConstVariantPtr args[] = {argument};
    variant_call(state->action_callback, &callable_call_name, args, 1, ret, &error);
    variant_destroy(argument);
    variant_destroy(ret);
}

static HICON create_farm_icon(void) {
    BITMAPV5HEADER info;
    memset(&info, 0, sizeof(info));
    info.bV5Size = sizeof(info); info.bV5Width = 32; info.bV5Height = -32;
    info.bV5Planes = 1; info.bV5BitCount = 32; info.bV5Compression = BI_BITFIELDS;
    info.bV5RedMask = 0x00ff0000; info.bV5GreenMask = 0x0000ff00;
    info.bV5BlueMask = 0x000000ff; info.bV5AlphaMask = 0xff000000;
    uint32_t *pixels = NULL;
    HDC dc = GetDC(NULL);
    HBITMAP color = CreateDIBSection(dc, (BITMAPINFO *)&info, DIB_RGB_COLORS,
        (void **)&pixels, NULL, 0);
    ReleaseDC(NULL, dc);
    if (!color) return NULL;
    memset(pixels, 0, 32 * 32 * sizeof(uint32_t));
    /* Original pixel sprout; no external icon files or Godot-logo fallback. */
    for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) {
        uint32_t color_value = 0;
        if (x >= 5 && x < 27 && y >= 23 && y < 28) color_value = 0xff6c4632;
        if (x >= 7 && x < 25 && y >= 20 && y < 24) color_value = 0xffaa7044;
        if (x >= 14 && x < 18 && y >= 10 && y < 21) color_value = 0xff3f7e3c;
        if (x >= 5 && x < 15 && y >= 6 && y < 12) color_value = 0xff6cb952;
        if (x >= 9 && x < 16 && y >= 10 && y < 14) color_value = 0xff4f923f;
        if (x >= 18 && x < 28 && y >= 3 && y < 9) color_value = 0xff96d66b;
        if (x >= 16 && x < 23 && y >= 7 && y < 12) color_value = 0xff5cad47;
        pixels[y * 32 + x] = color_value;
    }
    unsigned char mask_pixels[128] = {0};
    HBITMAP mask = CreateBitmap(32, 32, 1, 1, mask_pixels);
    ICONINFO icon_info = {0}; icon_info.fIcon = TRUE;
    icon_info.hbmColor = color; icon_info.hbmMask = mask;
    HICON icon = CreateIconIndirect(&icon_info);
    DeleteObject(color); if (mask) DeleteObject(mask);
    return icon;
}

static LRESULT CALLBACK shell_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    DesktopState *state = (DesktopState *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (msg == WM_NCCREATE) {
        state = (DesktopState *)((CREATESTRUCTW *)lp)->lpCreateParams;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)state);
    }
    if (!state) return DefWindowProcW(hwnd, msg, wp, lp);
    if (taskbar_created && msg == taskbar_created) {
        state->tray_registered = 0;
        install_tray(state);
        return 0;
    }
    if (msg == WM_HOTKEY && wp == FARM_HOTKEY_ID) { emit_action(state, 1); return 0; }
    if (msg == WM_COMMAND) {
        int action = LOWORD(wp) - FARM_MENU_BASE;
        if (action >= 1 && action <= 5) { emit_action(state, action); return 0; }
    }
    if (msg == FARM_TRAY_MESSAGE) {
        UINT notification = LOWORD(lp);
        if (notification == WM_LBUTTONDBLCLK || notification == NIN_KEYSELECT) {
            emit_action(state, 1); return 0;
        }
        if (notification == WM_CONTEXTMENU || notification == WM_RBUTTONUP) {
            HMENU menu = CreatePopupMenu();
            if (!menu) return 0;
            int hidden = state->shell_flags & 2;
            if (state->shell_flags & 4) {
                AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, L"全屏应用优先 · 农场自动隐藏");
                AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
            }
            AppendMenuW(menu, MF_STRING, FARM_MENU_BASE + 1, hidden ? L"显示农场" : L"隐藏农场");
            AppendMenuW(menu, MF_STRING, FARM_MENU_BASE + 2,
                (state->shell_flags & 1) ? L"切换为观赏模式" : L"切换为互动模式");
            AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
            AppendMenuW(menu, MF_STRING, FARM_MENU_BASE + 3, L"种子商店");
            AppendMenuW(menu, MF_STRING, FARM_MENU_BASE + 4, L"动物商店");
            AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
            AppendMenuW(menu, MF_STRING, FARM_MENU_BASE + 5, L"保存并退出");
            POINT point; GetCursorPos(&point);
            /* This occurs only after an explicit tray menu click. Automatic
             * restoration never calls SetForegroundWindow or raises a HWND. */
            SetForegroundWindow(hwnd);
            UINT selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                point.x, point.y, 0, hwnd, NULL);
            PostMessageW(hwnd, WM_NULL, 0, 0);
            DestroyMenu(menu);
            if (selected >= FARM_MENU_BASE + 1 && selected <= FARM_MENU_BASE + 5)
                emit_action(state, (int)(selected - FARM_MENU_BASE));
            return 0;
        }
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static int ensure_shell_window(DesktopState *state) {
    if (IsWindow(state->shell_hwnd)) return 1;
    if (!state->attached || !IsWindow(state->hwnd)) {
        state->shell_error = ERROR_INVALID_WINDOW_HANDLE; return 0;
    }
    WNDCLASSW cls = {0}; cls.lpfnWndProc = shell_proc;
    cls.hInstance = GetModuleHandleW(NULL); cls.lpszClassName = shell_class;
    if (!RegisterClassW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        state->shell_error = GetLastError(); return 0;
    }
    taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
    /* Never WS_VISIBLE: this message sink cannot create a blank desktop box. */
    state->shell_hwnd = CreateWindowExW(WS_EX_TOOLWINDOW, shell_class, L"DesktopFarm shell",
        WS_POPUP, 0, 0, 0, 0, NULL, NULL, cls.hInstance, state);
    if (!state->shell_hwnd) { state->shell_error = GetLastError(); return 0; }
    return 1;
}

static int install_tray(DesktopState *state) {
    if (state->tray_registered) return 1;
    if (!ensure_shell_window(state)) return 0;
    if (!state->tray_icon) state->tray_icon = create_farm_icon();
    if (!state->tray_icon) { state->shell_error = ERROR_NOT_ENOUGH_MEMORY; return 0; }
    NOTIFYICONDATAW info; memset(&info, 0, sizeof(info)); info.cbSize = sizeof(info);
    info.hWnd = state->shell_hwnd; info.uID = 1;
    info.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
    info.uCallbackMessage = FARM_TRAY_MESSAGE; info.hIcon = state->tray_icon;
    lstrcpynW(info.szTip, state->test_namespace ? L"桌面农场 · 测试实例" : L"桌面农场 · 双击显示/隐藏，右键打开商店", 128);
    if (!Shell_NotifyIconW(NIM_ADD, &info)) { state->shell_error = GetLastError(); return 0; }
    state->tray_registered = 1; state->shell_error = 0;
    info.uVersion = NOTIFYICON_VERSION_4; Shell_NotifyIconW(NIM_SETVERSION, &info);
    return 1;
}

static int register_hotkey(DesktopState *state) {
    if (state->hotkey_registered) return 1;
    if (!ensure_shell_window(state)) return 0;
    UINT modifiers = MOD_CONTROL | MOD_ALT | MOD_NOREPEAT;
    UINT key = 'F';
    if (state->test_namespace) { modifiers |= MOD_SHIFT; key = VK_F12; }
    if (!RegisterHotKey(state->shell_hwnd, FARM_HOTKEY_ID, modifiers, key)) {
        state->shell_error = GetLastError(); return 0;
    }
    state->hotkey_registered = 1; state->shell_error = 0; return 1;
}

static void shutdown_shell(DesktopState *state) {
    if (state->hotkey_registered) UnregisterHotKey(state->shell_hwnd, FARM_HOTKEY_ID);
    state->hotkey_registered = 0;
    if (state->tray_registered) {
        NOTIFYICONDATAW info; memset(&info, 0, sizeof(info)); info.cbSize = sizeof(info);
        info.hWnd = state->shell_hwnd; info.uID = 1; Shell_NotifyIconW(NIM_DELETE, &info);
    }
    state->tray_registered = 0;
    if (IsWindow(state->shell_hwnd)) DestroyWindow(state->shell_hwnd);
    state->shell_hwnd = NULL;
    if (state->tray_icon) DestroyIcon(state->tray_icon);
    state->tray_icon = NULL;
}

static LRESULT CALLBACK power_subclass(HWND hwnd, UINT msg, WPARAM wparam,
        LPARAM lparam, UINT_PTR id, DWORD_PTR data) {
    (void) id;
    DesktopState *state = (DesktopState *)data;
    if (msg == WM_POWERBROADCAST) {
        if (wparam == PBT_APMSUSPEND) {
            InterlockedExchange(&suspended, 1);
            InterlockedIncrement(&suspend_epoch);
            InterlockedIncrement(&power_epoch);
            /* WM_POWERBROADCAST is delivered on the window's main thread.
             * Saving synchronously here happens before Windows suspends; polling
             * this event only after wake would be too late for the last snapshot. */
            if (state->has_suspend_callback) {
                uint64_t ret[3];
                GDExtensionCallError error;
                variant_call(state->suspend_callback, &callable_call_name, NULL, 0, ret, &error);
                variant_destroy(ret);
            }
        } else if (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND) {
            if (InterlockedExchange(&suspended, 0)) InterlockedIncrement(&power_epoch);
        }
    }
    return DefSubclassProc(hwnd, msg, wparam, lparam);
}

/* Public C entry points also permit a standalone Windows integration probe. */
__declspec(dllexport) int desktop_make_normal_window(HWND hwnd) {
    if (!IsWindow(hwnd)) return 0;
    /* Only demote an existing topmost window. HWND_NOTOPMOST also moves an
     * ordinary window within its Z band, so repeated calls must be a no-op. */
    if (GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) {
        if (!SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)) return 0;
    }
    return (GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOPMOST) == 0;
}

__declspec(dllexport) int desktop_show_without_raise(HWND hwnd) {
    if (!desktop_make_normal_window(hwnd)) return 0;
    if (!IsWindowVisible(hwnd)) ShowWindow(hwnd, SW_SHOWNA);
    return IsWindowVisible(hwnd) != 0;
}

static int hide_from_taskbar(HWND hwnd) {
    LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    LONG_PTR hidden_style = (style | WS_EX_TOOLWINDOW) & ~(LONG_PTR)WS_EX_APPWINDOW;
    if (style == hidden_style) return 1;
    BOOL visible = IsWindowVisible(hwnd);
    if (visible) ShowWindow(hwnd, SW_HIDE);
    SetLastError(0);
    int ok = SetWindowLongPtrW(hwnd, GWL_EXSTYLE, hidden_style) != 0 || !GetLastError();
    SetWindowPos(hwnd, NULL, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    if (visible) ShowWindow(hwnd, SW_SHOWNA);
    return ok;
}

__declspec(dllexport) int desktop_apply_style(HWND hwnd, int interactive) {
    if (!IsWindow(hwnd)) return 0;
    LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    style |= WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
    if (interactive) style &= ~(LONG_PTR)WS_EX_TRANSPARENT;
    else style |= WS_EX_TRANSPARENT;
    SetLastError(0);
    if (!SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style) && GetLastError()) return 0;
    SetWindowPos(hwnd, NULL, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    return desktop_make_normal_window(hwnd);
}

__declspec(dllexport) uint64_t desktop_awake_msec(void) {
    ULONGLONG ticks = 0;
    if (!QueryUnbiasedInterruptTime(&ticks)) return 0;
    return (uint64_t)(ticks / 10000ULL);
}

static void detach(DesktopState *state) {
    shutdown_shell(state);
    if (state->attached && IsWindow(state->hwnd)) {
        RemoveWindowSubclass(state->hwnd, power_subclass, (UINT_PTR)state);
        SetWindowLongPtrW(state->hwnd, GWL_EXSTYLE, state->previous_style);
        SetWindowPos(state->hwnd, NULL, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    }
    state->hwnd = NULL;
    state->attached = 0;
}

static int attach(DesktopState *state, int64_t handle) {
    HWND hwnd = (HWND)(intptr_t)handle;
    DWORD process_id = 0;
    GetWindowThreadProcessId(hwnd, &process_id);
    if (!IsWindow(hwnd) || process_id != GetCurrentProcessId()) return 0;
    if (state->attached && state->hwnd == hwnd) return 1;
    detach(state);
    state->hwnd = hwnd;
    state->previous_style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    if (!SetWindowSubclass(hwnd, power_subclass, (UINT_PTR)state, (DWORD_PTR)state)) {
        state->hwnd = NULL;
        return 0;
    }
    state->attached = 1;
    if (!hide_from_taskbar(hwnd) || !desktop_apply_style(hwnd, 0)) {
        detach(state);
        return 0;
    }
    return 1;
}

static int try_single_instance(DesktopState *state) {
    if (state->singleton) return 1;
    SetLastError(0);
    wchar_t mutex_name[128];
    if (state->test_namespace) wsprintfW(mutex_name, L"Local\\DesktopFarm.v07.test.%lu", GetCurrentProcessId());
    else lstrcpynW(mutex_name, L"Local\\DesktopFarm.v05.single-instance", 128);
    HANDLE mutex = CreateMutexW(NULL, FALSE, mutex_name);
    if (!mutex) return 0;
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        CloseHandle(mutex);
        return 0;
    }
    state->singleton = mutex;
    return 1;
}

static void release(DesktopState *state) {
    detach(state);
    if (state->singleton) CloseHandle(state->singleton);
    state->singleton = NULL;
    if (state->has_suspend_callback) variant_destroy(state->suspend_callback);
    state->has_suspend_callback = 0;
    if (state->has_action_callback) variant_destroy(state->action_callback);
    state->has_action_callback = 0;
}

static void work_area(DesktopState *state, int32_t result[4]) {
    MONITORINFO info;
    memset(&info, 0, sizeof(info));
    info.cbSize = sizeof(info);
    HMONITOR monitor = state->hwnd ? MonitorFromWindow(state->hwnd, MONITOR_DEFAULTTONEAREST)
        : MonitorFromPoint((POINT){0, 0}, MONITOR_DEFAULTTOPRIMARY);
    RECT area;
    if (GetMonitorInfoW(monitor, &info)) area = info.rcWork;
    else if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &area, 0)) {
        area = (RECT){0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)};
    }
    result[0] = area.left; result[1] = area.top;
    result[2] = area.right - area.left; result[3] = area.bottom - area.top;
}

static double dpi_scale(DesktopState *state) {
    typedef UINT (WINAPI *DpiForWindow)(HWND);
    DpiForWindow get_dpi = (DpiForWindow)(void *)GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow");
    UINT dpi = get_dpi && state->hwnd ? get_dpi(state->hwnd) : 96;
    return dpi ? (double)dpi / 96.0 : 1.0;
}

/* native_status flags: attached=1, layered=2, transparent=4, noactivate=8,
 * toolwindow=16, unbiased clock available=32, power hook=64, single-instance=128. */
static int64_t status(DesktopState *state) {
    int64_t result = 0;
    if (state->attached && IsWindow(state->hwnd)) {
        LONG_PTR flags = GetWindowLongPtrW(state->hwnd, GWL_EXSTYLE);
        result |= 1 | 64;
        if (flags & WS_EX_LAYERED) result |= 2;
        if (flags & WS_EX_TRANSPARENT) result |= 4;
        if (flags & WS_EX_NOACTIVATE) result |= 8;
        if (flags & WS_EX_TOOLWINDOW) result |= 16;
    }
    ULONGLONG ticks;
    if (QueryUnbiasedInterruptTime(&ticks)) result |= 32;
    if (state->singleton) result |= 128;
    return result;
}

static int set_visible(DesktopState *state, int visible) {
    if (!state->attached || !IsWindow(state->hwnd)) return 0;
    if (visible) return desktop_show_without_raise(state->hwnd);
    if (IsWindowVisible(state->hwnd)) ShowWindow(state->hwnd, SW_HIDE);
    return (IsWindowVisible(state->hwnd) != 0) == (visible != 0);
}

static int make_independent_window(int64_t handle) {
    HWND hwnd = (HWND)(intptr_t)handle;
    DWORD process_id = 0;
    GetWindowThreadProcessId(hwnd, &process_id);
    if (!IsWindow(hwnd) || process_id != GetCurrentProcessId() ||
        (GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_CHILD)) return 0;
    /* Windows hides owned popup windows whenever their owner is hidden.
     * A detached, top-level toolbar must survive hiding the scenery HWND. */
    if (GetWindow(hwnd, GW_OWNER) == NULL) return desktop_make_normal_window(hwnd);
    SetLastError(0);
    LONG_PTR old_owner = SetWindowLongPtrW(hwnd, GWLP_HWNDPARENT, 0);
    if (!old_owner && GetLastError() && GetWindow(hwnd, GW_OWNER) != NULL) return 0;
    return GetWindow(hwnd, GW_OWNER) == NULL && desktop_make_normal_window(hwnd);
}

static int hide_auxiliary_taskbar_entry(int64_t handle) {
    HWND hwnd = (HWND)(intptr_t)handle;
    DWORD process_id = 0;
    GetWindowThreadProcessId(hwnd, &process_id);
    return process_id == GetCurrentProcessId() && hide_from_taskbar(hwnd);
}

static void raise_scene_with_toolbar(DesktopState *state, int64_t handle) {
    HWND toolbar = (HWND)(intptr_t)handle;
    if (!state->attached || !IsWindowVisible(state->hwnd) || GetForegroundWindow() != toolbar) return;
    SetWindowPos(state->hwnd, toolbar, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

static int show_window(int64_t handle) {
    HWND hwnd = (HWND)(intptr_t)handle;
    DWORD process_id = 0;
    GetWindowThreadProcessId(hwnd, &process_id);
    if (!IsWindow(hwnd) || process_id != GetCurrentProcessId()) return 0;
    return desktop_show_without_raise(hwnd);
}

static int hide_window(int64_t handle) {
    HWND hwnd = (HWND)(intptr_t)handle;
    DWORD process_id = 0; GetWindowThreadProcessId(hwnd, &process_id);
    if (!IsWindow(hwnd) || process_id != GetCurrentProcessId()) return 0;
    if (IsWindowVisible(hwnd)) ShowWindow(hwnd, SW_HIDE);
    return !IsWindowVisible(hwnd);
}

__declspec(dllexport) int desktop_foreground_fullscreen(HWND scene) {
    HWND foreground = GetForegroundWindow();
    if (!IsWindow(foreground) || IsIconic(foreground) || !IsWindowVisible(foreground)) return 0;
    DWORD process_id = 0; GetWindowThreadProcessId(foreground, &process_id);
    if (process_id == GetCurrentProcessId()) return 0;
    wchar_t name[128]; GetClassNameW(foreground, name, 128);
    if (lstrcmpW(name, L"Progman") == 0 || lstrcmpW(name, L"WorkerW") == 0 ||
        lstrcmpW(name, L"Shell_TrayWnd") == 0 || lstrcmpW(name, L"Shell_SecondaryTrayWnd") == 0) return 0;
    LONG_PTR style = GetWindowLongPtrW(foreground, GWL_STYLE);
    if (IsZoomed(foreground) && (style & WS_CAPTION) == WS_CAPTION) return 0;
    HMONITOR target = MonitorFromWindow(scene, MONITOR_DEFAULTTONEAREST);
    if (MonitorFromWindow(foreground, MONITOR_DEFAULTTONEAREST) != target) return 0;
    typedef HRESULT (WINAPI *GetDwmAttribute)(HWND, DWORD, PVOID, DWORD);
    HMODULE dwm = LoadLibraryW(L"dwmapi.dll");
    GetDwmAttribute get_attribute = dwm ? (GetDwmAttribute)(void *)GetProcAddress(dwm, "DwmGetWindowAttribute") : NULL;
    DWORD cloaked = 0;
    if (get_attribute && SUCCEEDED(get_attribute(foreground, 14, &cloaked, sizeof(cloaked))) && cloaked) {
        FreeLibrary(dwm); return 0;
    }
    RECT rect;
    int has_frame = get_attribute && SUCCEEDED(get_attribute(foreground, 9, &rect, sizeof(rect)));
    if (dwm) FreeLibrary(dwm);
    if (!has_frame && !GetWindowRect(foreground, &rect)) return 0;
    MONITORINFO monitor = {0}; monitor.cbSize = sizeof(monitor);
    if (!GetMonitorInfoW(target, &monitor)) return 0;
    RECT bounds = monitor.rcMonitor;
    /* A regular maximized work-area window leaves the taskbar outside its
     * bounds. Only actual whole-monitor coverage suppresses the farm. */
    return rect.left <= bounds.left + 1 && rect.top <= bounds.top + 1 &&
        rect.right >= bounds.right - 1 && rect.bottom >= bounds.bottom - 1;
}

typedef enum { ATTACH, INTERACTIVE, AREA, AWAKE, SINGLE, RELEASE,
    SUSPENDED, POWER_EPOCH, SUSPEND_EPOCH, STATUS, DPI, SUSPEND_CALLBACK,
    SET_VISIBLE, IS_VISIBLE, WINDOW_IS_VISIBLE, INDEPENDENT_WINDOW, SHOW_WINDOW,
    WINDOW_IS_TOPMOST, WINDOW_HIDE, ACTION_CALLBACK, INSTALL_TRAY, REGISTER_HOTKEY,
    TRAY_REGISTERED, HOTKEY_REGISTERED, SHELL_ERROR, SHELL_HANDLE, SHELL_FLAGS,
    TEST_NAMESPACE, FOREGROUND_FULLSCREEN, HIDE_TASKBAR_ENTRY, RAISE_WITH_TOOLBAR } Method;
typedef struct { const char *name; Method id; GDExtensionVariantType ret, arg; } MethodSpec;
static const MethodSpec methods[] = {
    {"attach", ATTACH, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_INT},
    {"set_interactive", INTERACTIVE, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_BOOL},
    {"get_work_area", AREA, GDEXTENSION_VARIANT_TYPE_RECT2I, GDEXTENSION_VARIANT_TYPE_NIL},
    {"elapsed_awake_msec", AWAKE, GDEXTENSION_VARIANT_TYPE_INT, GDEXTENSION_VARIANT_TYPE_NIL},
    {"try_single_instance", SINGLE, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_NIL},
    {"release", RELEASE, GDEXTENSION_VARIANT_TYPE_NIL, GDEXTENSION_VARIANT_TYPE_NIL},
    {"is_suspended", SUSPENDED, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_NIL},
    {"power_epoch", POWER_EPOCH, GDEXTENSION_VARIANT_TYPE_INT, GDEXTENSION_VARIANT_TYPE_NIL},
    {"suspend_epoch", SUSPEND_EPOCH, GDEXTENSION_VARIANT_TYPE_INT, GDEXTENSION_VARIANT_TYPE_NIL},
    {"native_status", STATUS, GDEXTENSION_VARIANT_TYPE_INT, GDEXTENSION_VARIANT_TYPE_NIL},
    {"get_dpi_scale", DPI, GDEXTENSION_VARIANT_TYPE_FLOAT, GDEXTENSION_VARIANT_TYPE_NIL},
    {"set_suspend_callback", SUSPEND_CALLBACK, GDEXTENSION_VARIANT_TYPE_NIL, GDEXTENSION_VARIANT_TYPE_CALLABLE},
    {"set_visible", SET_VISIBLE, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_BOOL},
    {"is_visible", IS_VISIBLE, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_NIL},
    {"window_is_visible", WINDOW_IS_VISIBLE, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_INT},
    {"make_independent_window", INDEPENDENT_WINDOW, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_INT},
    {"hide_taskbar_entry", HIDE_TASKBAR_ENTRY, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_INT},
    {"raise_scene_with_toolbar", RAISE_WITH_TOOLBAR, GDEXTENSION_VARIANT_TYPE_NIL, GDEXTENSION_VARIANT_TYPE_INT},
    {"show_window", SHOW_WINDOW, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_INT},
    {"window_is_topmost", WINDOW_IS_TOPMOST, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_INT},
    {"hide_window", WINDOW_HIDE, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_INT},
    {"set_action_callback", ACTION_CALLBACK, GDEXTENSION_VARIANT_TYPE_NIL, GDEXTENSION_VARIANT_TYPE_CALLABLE},
    {"install_tray", INSTALL_TRAY, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_NIL},
    {"register_toggle_hotkey", REGISTER_HOTKEY, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_NIL},
    {"tray_registered", TRAY_REGISTERED, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_NIL},
    {"hotkey_registered", HOTKEY_REGISTERED, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_NIL},
    {"shell_last_error", SHELL_ERROR, GDEXTENSION_VARIANT_TYPE_INT, GDEXTENSION_VARIANT_TYPE_NIL},
    {"shell_window_handle", SHELL_HANDLE, GDEXTENSION_VARIANT_TYPE_INT, GDEXTENSION_VARIANT_TYPE_NIL},
    {"set_shell_state", SHELL_FLAGS, GDEXTENSION_VARIANT_TYPE_NIL, GDEXTENSION_VARIANT_TYPE_INT},
    {"set_test_namespace", TEST_NAMESPACE, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_BOOL},
    {"foreground_is_fullscreen", FOREGROUND_FULLSCREEN, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_NIL}
};

static void execute(Method id, DesktopState *state, int64_t integer,
        GDExtensionBool boolean, void *result) {
    switch (id) {
        case ATTACH: *(GDExtensionBool *)result = (GDExtensionBool)attach(state, integer); break;
        case INTERACTIVE: *(GDExtensionBool *)result = (GDExtensionBool)desktop_apply_style(state->hwnd, boolean); break;
        case AREA: work_area(state, (int32_t *)result); break;
        case AWAKE: *(int64_t *)result = (int64_t)desktop_awake_msec(); break;
        case SINGLE: *(GDExtensionBool *)result = (GDExtensionBool)try_single_instance(state); break;
        case RELEASE: release(state); break;
        case SUSPENDED: *(GDExtensionBool *)result = (GDExtensionBool)InterlockedCompareExchange(&suspended, 0, 0); break;
        case POWER_EPOCH: *(int64_t *)result = InterlockedCompareExchange(&power_epoch, 0, 0); break;
        case SUSPEND_EPOCH: *(int64_t *)result = InterlockedCompareExchange(&suspend_epoch, 0, 0); break;
        case STATUS: *(int64_t *)result = status(state); break;
        case DPI: *(double *)result = dpi_scale(state); break;
        case SUSPEND_CALLBACK: break;
        case SET_VISIBLE: *(GDExtensionBool *)result = (GDExtensionBool)set_visible(state, boolean); break;
        case IS_VISIBLE: *(GDExtensionBool *)result = state->attached && IsWindowVisible(state->hwnd); break;
        case WINDOW_IS_VISIBLE: *(GDExtensionBool *)result = IsWindowVisible((HWND)(intptr_t)integer) != 0; break;
        case INDEPENDENT_WINDOW: *(GDExtensionBool *)result = (GDExtensionBool)make_independent_window(integer); break;
        case HIDE_TASKBAR_ENTRY: *(GDExtensionBool *)result = (GDExtensionBool)hide_auxiliary_taskbar_entry(integer); break;
        case RAISE_WITH_TOOLBAR: raise_scene_with_toolbar(state, integer); break;
        case SHOW_WINDOW: *(GDExtensionBool *)result = (GDExtensionBool)show_window(integer); break;
        case WINDOW_IS_TOPMOST: *(GDExtensionBool *)result =
            (GetWindowLongPtrW((HWND)(intptr_t)integer, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0; break;
        case WINDOW_HIDE: *(GDExtensionBool *)result = (GDExtensionBool)hide_window(integer); break;
        case ACTION_CALLBACK: break;
        case INSTALL_TRAY: *(GDExtensionBool *)result = (GDExtensionBool)install_tray(state); break;
        case REGISTER_HOTKEY: *(GDExtensionBool *)result = (GDExtensionBool)register_hotkey(state); break;
        case TRAY_REGISTERED: *(GDExtensionBool *)result = (GDExtensionBool)state->tray_registered; break;
        case HOTKEY_REGISTERED: *(GDExtensionBool *)result = (GDExtensionBool)state->hotkey_registered; break;
        case SHELL_ERROR: *(int64_t *)result = state->shell_error; break;
        case SHELL_HANDLE: *(int64_t *)result = (int64_t)(intptr_t)state->shell_hwnd; break;
        case SHELL_FLAGS: state->shell_flags = (int)integer; break;
        case TEST_NAMESPACE:
            *(GDExtensionBool *)result = 0;
            if (!state->singleton && !state->attached) {
                state->test_namespace = boolean != 0;
                *(GDExtensionBool *)result = 1;
            }
            break;
        case FOREGROUND_FULLSCREEN: *(GDExtensionBool *)result =
            (GDExtensionBool)desktop_foreground_fullscreen(state->hwnd); break;
    }
}

static void ptrcall(void *userdata, GDExtensionClassInstancePtr instance,
        const GDExtensionConstTypePtr *args, GDExtensionTypePtr ret) {
    const MethodSpec *method = (const MethodSpec *)userdata;
    if (method->id == SUSPEND_CALLBACK || method->id == ACTION_CALLBACK) {
        DesktopState *state = (DesktopState *)instance;
        uint64_t *callback = method->id == SUSPEND_CALLBACK ? state->suspend_callback : state->action_callback;
        int *present = method->id == SUSPEND_CALLBACK ? &state->has_suspend_callback : &state->has_action_callback;
        if (*present) variant_destroy(callback);
        from_type[GDEXTENSION_VARIANT_TYPE_CALLABLE](callback, (void *)args[0]);
        *present = 1;
        return;
    }
    int64_t integer = method->arg == GDEXTENSION_VARIANT_TYPE_INT ? *(const int64_t *)args[0] : 0;
    GDExtensionBool boolean = method->arg == GDEXTENSION_VARIANT_TYPE_BOOL ? *(const GDExtensionBool *)args[0] : 0;
    execute(method->id, (DesktopState *)instance, integer, boolean, ret);
}

static void call(void *userdata, GDExtensionClassInstancePtr instance,
        const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
        GDExtensionVariantPtr ret, GDExtensionCallError *error) {
    const MethodSpec *method = (const MethodSpec *)userdata;
    int wanted = method->arg == GDEXTENSION_VARIANT_TYPE_NIL ? 0 : 1;
    error->error = GDEXTENSION_CALL_OK;
    error->argument = 0;
    error->expected = wanted;
    if (argc != wanted) {
        error->error = argc > wanted ? GDEXTENSION_CALL_ERROR_TOO_MANY_ARGUMENTS : GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
        variant_nil(ret); return;
    }
    if (wanted && variant_type(args[0]) != method->arg) {
        error->error = GDEXTENSION_CALL_ERROR_INVALID_ARGUMENT;
        error->expected = method->arg;
        variant_nil(ret); return;
    }
    if (method->id == SUSPEND_CALLBACK || method->id == ACTION_CALLBACK) {
        DesktopState *state = (DesktopState *)instance;
        uint64_t *callback = method->id == SUSPEND_CALLBACK ? state->suspend_callback : state->action_callback;
        int *present = method->id == SUSPEND_CALLBACK ? &state->has_suspend_callback : &state->has_action_callback;
        if (*present) variant_destroy(callback);
        variant_copy(callback, args[0]);
        *present = 1;
        variant_nil(ret); return;
    }
    int64_t integer = 0;
    GDExtensionBool boolean = 0;
    if (method->arg == GDEXTENSION_VARIANT_TYPE_INT) to_type[method->arg](&integer, (void *)args[0]);
    if (method->arg == GDEXTENSION_VARIANT_TYPE_BOOL) to_type[method->arg](&boolean, (void *)args[0]);
    union { uint64_t align; int32_t area[4]; double number; int64_t integer; GDExtensionBool boolean; } result;
    memset(&result, 0, sizeof(result));
    execute(method->id, (DesktopState *)instance, integer, boolean, &result);
    if (method->ret == GDEXTENSION_VARIANT_TYPE_NIL) variant_nil(ret);
    else from_type[method->ret](ret, &result);
}

static GDExtensionObjectPtr create(void *userdata, GDExtensionBool notify) {
    (void)userdata;
    DesktopState *state = (DesktopState *)calloc(1, sizeof(DesktopState));
    if (!state) return NULL;
    state->object = construct_object(&parent_name);
    object_set_instance(state->object, &class_name, state);
    if (notify && postinitialize) {
        int32_t what = 0; /* Object::NOTIFICATION_POSTINITIALIZE */
        GDExtensionBool reversed = 0;
        const GDExtensionConstTypePtr args[] = {&what, &reversed};
        object_ptrcall(postinitialize, state->object, args, NULL);
    }
    return state->object;
}

static void destroy(void *userdata, GDExtensionClassInstancePtr instance) {
    (void)userdata;
    DesktopState *state = (DesktopState *)instance;
    release(state);
    free(state);
}

static GDExtensionPropertyInfo property(GDExtensionVariantType type) {
    GDExtensionPropertyInfo info;
    memset(&info, 0, sizeof(info));
    info.type = type;
    info.name = &empty_name;
    info.class_name = &empty_name;
    info.hint_string = &empty_string;
    info.usage = 6; /* PROPERTY_USAGE_DEFAULT */
    return info;
}

static void initialize(void *userdata, GDExtensionInitializationLevel level) {
    (void)userdata;
    if (level != GDEXTENSION_INITIALIZATION_SCENE) return;
    sn_new(&class_name, "DesktopNative"); sn_new(&parent_name, "RefCounted");
    sn_new(&empty_name, ""); str_new(&empty_string, "");
    sn_new(&callable_call_name, "call");
    uint64_t object_name, notification_name;
    sn_new(&object_name, "Object"); sn_new(&notification_name, "notification");
    /* Verified against the locked engine's extension_api.json. */
    postinitialize = get_method_bind(&object_name, &notification_name, 4023243586LL);
    sn_destroy(&object_name); sn_destroy(&notification_name);
    GDExtensionClassCreationInfo4 info;
    memset(&info, 0, sizeof(info));
    info.is_exposed = 1; info.is_runtime = 1;
    info.create_instance_func = create;
    info.free_instance_func = destroy;
    register_class(library, &class_name, &parent_name, &info);
    for (size_t i = 0; i < sizeof(methods) / sizeof(methods[0]); i++) {
        uint64_t name;
        sn_new(&name, methods[i].name);
        GDExtensionPropertyInfo ret = property(methods[i].ret), arg = property(methods[i].arg);
        GDExtensionClassMethodArgumentMetadata metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE;
        GDExtensionClassMethodInfo method;
        memset(&method, 0, sizeof(method));
        method.name = &name; method.method_userdata = (void *)&methods[i];
        method.call_func = call; method.ptrcall_func = ptrcall;
        method.method_flags = GDEXTENSION_METHOD_FLAG_NORMAL;
        method.has_return_value = methods[i].ret != GDEXTENSION_VARIANT_TYPE_NIL;
        method.return_value_info = &ret;
        method.argument_count = methods[i].arg == GDEXTENSION_VARIANT_TYPE_NIL ? 0 : 1;
        method.arguments_info = &arg; method.arguments_metadata = &metadata;
        register_method(library, &class_name, &method);
        sn_destroy(&name);
    }
}

static void terminate(void *userdata, GDExtensionInitializationLevel level) {
    (void)userdata;
    if (level != GDEXTENSION_INITIALIZATION_SCENE) return;
    unregister_class(library, &class_name);
    sn_destroy(&class_name); sn_destroy(&parent_name); sn_destroy(&empty_name); str_destroy(&empty_string);
    sn_destroy(&callable_call_name);
}

__declspec(dllexport) GDExtensionBool desktop_library_init(
        GDExtensionInterfaceGetProcAddress get_proc, GDExtensionClassLibraryPtr handle,
        GDExtensionInitialization *initialization) {
    library = handle;
#define LOAD(name, type, entry) do { GDExtensionInterfaceFunctionPtr address = get_proc(entry); \
    memcpy(&name, &address, sizeof(type)); if (!name) return 0; } while (0)
    LOAD(sn_new, GDExtensionInterfaceStringNameNewWithUtf8Chars, "string_name_new_with_utf8_chars");
    LOAD(str_new, GDExtensionInterfaceStringNewWithUtf8Chars, "string_new_with_utf8_chars");
    LOAD(construct_object, GDExtensionInterfaceClassdbConstructObject2, "classdb_construct_object2");
    LOAD(get_method_bind, GDExtensionInterfaceClassdbGetMethodBind, "classdb_get_method_bind");
    LOAD(object_ptrcall, GDExtensionInterfaceObjectMethodBindPtrcall, "object_method_bind_ptrcall");
    LOAD(object_set_instance, GDExtensionInterfaceObjectSetInstance, "object_set_instance");
    LOAD(register_class, GDExtensionInterfaceClassdbRegisterExtensionClass4, "classdb_register_extension_class4");
    LOAD(register_method, GDExtensionInterfaceClassdbRegisterExtensionClassMethod, "classdb_register_extension_class_method");
    LOAD(unregister_class, GDExtensionInterfaceClassdbUnregisterExtensionClass, "classdb_unregister_extension_class");
    LOAD(variant_nil, GDExtensionInterfaceVariantNewNil, "variant_new_nil");
    LOAD(variant_copy, GDExtensionInterfaceVariantNewCopy, "variant_new_copy");
    LOAD(variant_destroy, GDExtensionInterfaceVariantDestroy, "variant_destroy");
    LOAD(variant_call, GDExtensionInterfaceVariantCall, "variant_call");
    LOAD(variant_type, GDExtensionInterfaceVariantGetType, "variant_get_type");
    GDExtensionInterfaceGetVariantFromTypeConstructor from;
    GDExtensionInterfaceGetVariantToTypeConstructor to;
    GDExtensionInterfaceVariantGetPtrDestructor destructor;
    LOAD(from, GDExtensionInterfaceGetVariantFromTypeConstructor, "get_variant_from_type_constructor");
    LOAD(to, GDExtensionInterfaceGetVariantToTypeConstructor, "get_variant_to_type_constructor");
    LOAD(destructor, GDExtensionInterfaceVariantGetPtrDestructor, "variant_get_ptr_destructor");
    for (int i = 1; i < GDEXTENSION_VARIANT_TYPE_VARIANT_MAX; i++) { from_type[i] = from(i); to_type[i] = to(i); }
    sn_destroy = destructor(GDEXTENSION_VARIANT_TYPE_STRING_NAME);
    str_destroy = destructor(GDEXTENSION_VARIANT_TYPE_STRING);
    initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
    initialization->userdata = NULL;
    initialization->initialize = initialize;
    initialization->deinitialize = terminate;
    return 1;
}
