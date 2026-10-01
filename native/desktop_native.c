/* Minimal Godot C ABI bridge. The Godot interface header retains its MIT notice. */
#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#include <windows.h>
#include <commctrl.h>
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
} DesktopState;

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
    if (!desktop_apply_style(hwnd, 0)) {
        detach(state);
        return 0;
    }
    return 1;
}

static int try_single_instance(DesktopState *state) {
    if (state->singleton) return 1;
    SetLastError(0);
    HANDLE mutex = CreateMutexW(NULL, FALSE, L"Local\\DesktopFarm.v05.single-instance");
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

static int show_window(int64_t handle) {
    HWND hwnd = (HWND)(intptr_t)handle;
    DWORD process_id = 0;
    GetWindowThreadProcessId(hwnd, &process_id);
    if (!IsWindow(hwnd) || process_id != GetCurrentProcessId()) return 0;
    return desktop_show_without_raise(hwnd);
}

typedef enum { ATTACH, INTERACTIVE, AREA, AWAKE, SINGLE, RELEASE,
    SUSPENDED, POWER_EPOCH, SUSPEND_EPOCH, STATUS, DPI, SUSPEND_CALLBACK,
    SET_VISIBLE, IS_VISIBLE, WINDOW_IS_VISIBLE, INDEPENDENT_WINDOW, SHOW_WINDOW,
    WINDOW_IS_TOPMOST } Method;
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
    {"show_window", SHOW_WINDOW, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_INT},
    {"window_is_topmost", WINDOW_IS_TOPMOST, GDEXTENSION_VARIANT_TYPE_BOOL, GDEXTENSION_VARIANT_TYPE_INT}
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
        case SHOW_WINDOW: *(GDExtensionBool *)result = (GDExtensionBool)show_window(integer); break;
        case WINDOW_IS_TOPMOST: *(GDExtensionBool *)result =
            (GetWindowLongPtrW((HWND)(intptr_t)integer, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0; break;
    }
}

static void ptrcall(void *userdata, GDExtensionClassInstancePtr instance,
        const GDExtensionConstTypePtr *args, GDExtensionTypePtr ret) {
    const MethodSpec *method = (const MethodSpec *)userdata;
    if (method->id == SUSPEND_CALLBACK) {
        DesktopState *state = (DesktopState *)instance;
        if (state->has_suspend_callback) variant_destroy(state->suspend_callback);
        from_type[GDEXTENSION_VARIANT_TYPE_CALLABLE](state->suspend_callback, (void *)args[0]);
        state->has_suspend_callback = 1;
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
    if (method->id == SUSPEND_CALLBACK) {
        DesktopState *state = (DesktopState *)instance;
        if (state->has_suspend_callback) variant_destroy(state->suspend_callback);
        variant_copy(state->suspend_callback, args[0]);
        state->has_suspend_callback = 1;
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
