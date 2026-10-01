/* Integration test: a real mouse click traverses a layered HWND to a window
 * owned by a different process, then is intercepted when interaction is on. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

typedef struct { volatile LONG clicks; volatile LONG alive; uintptr_t hwnd; } Shared;
static Shared *shared;
static int overlay_clicks;

static LRESULT CALLBACK target_proc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
    if (message == WM_APP + 1) {
        AllowSetForegroundWindow((DWORD)wp);
        return 0;
    }
    if (message == WM_LBUTTONDOWN) {
        if (shared) InterlockedIncrement(&shared->clicks);
        else overlay_clicks++;
        return 0;
    }
    if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(hwnd, message, wp, lp);
}

static void pump(DWORD duration) {
    ULONGLONG until = GetTickCount64() + duration;
    MSG message;
    do {
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message); DispatchMessageW(&message);
        }
        Sleep(5);
    } while (GetTickCount64() < until);
}

static HWND make_window(const wchar_t *title, int x, int y, int width, int height, int overlay) {
    WNDCLASSW cls = {0};
    cls.lpfnWndProc = target_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.lpszClassName = L"DesktopFarmClickProbe";
    cls.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassW(&cls);
    HWND hwnd = CreateWindowExW(overlay ? WS_EX_LAYERED | WS_EX_NOACTIVATE : WS_EX_TOOLWINDOW,
        cls.lpszClassName, title, WS_POPUP, x, y, width, height, NULL, NULL, cls.hInstance, NULL);
    if (overlay) SetLayeredWindowAttributes(hwnd, 0, 210, LWA_ALPHA);
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    SetWindowPos(hwnd, overlay ? HWND_TOPMOST : HWND_TOP, x, y, width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    return hwnd;
}

static int click_at(int x, int y) {
    if (!SetCursorPos(x, y)) return 0;
    INPUT input[2];
    ZeroMemory(input, sizeof(input));
    input[0].type = input[1].type = INPUT_MOUSE;
    input[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    input[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    return SendInput(2, input, sizeof(INPUT)) == 2;
}

int wmain(int argc, wchar_t **argv) {
    if (argc >= 6 && wcscmp(argv[1], L"--child") == 0) {
        HANDLE mapping = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, argv[2]);
        if (!mapping) return 10;
        shared = (Shared *)MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(Shared));
        HWND target = make_window(L"Farm input probe target", _wtoi(argv[3]), _wtoi(argv[4]), 320, 160, 0);
        shared->hwnd = (uintptr_t)target;
        InterlockedExchange(&shared->alive, 1);
        MSG message;
        while (GetMessageW(&message, NULL, 0, 0) > 0) { TranslateMessage(&message); DispatchMessageW(&message); }
        UnmapViewOfFile(shared); CloseHandle(mapping);
        return 0;
    }
    if (argc < 2) { fwprintf(stderr, L"Usage: click_probe.exe full_path_to_desktop_native.dll\n"); return 2; }
    HMODULE library = LoadLibraryW(argv[1]);
    if (!library) { printf("LOAD_FAILED %lu\n", GetLastError()); return 3; }
    typedef int (*ApplyStyle)(HWND, int);
    ApplyStyle apply = (ApplyStyle)(void *)GetProcAddress(library, "desktop_apply_style");
    if (!apply) return 4;
    wchar_t mapping_name[128], executable[MAX_PATH], command[1024];
    swprintf(mapping_name, 128, L"Local\\FarmClickProbe.%lu", GetCurrentProcessId());
    HANDLE mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, sizeof(Shared), mapping_name);
    Shared *target_state = (Shared *)MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(Shared));
    ZeroMemory(target_state, sizeof(Shared));
    RECT work;
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    int x = work.left + 80, y = work.top + 80;
    GetModuleFileNameW(NULL, executable, MAX_PATH);
    swprintf(command, 1024, L"\"%ls\" --child %ls %d %d ready", executable, mapping_name, x, y);
    STARTUPINFOW startup = {0}; PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup); startup.dwFlags = STARTF_USESHOWWINDOW; startup.wShowWindow = SW_HIDE;
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &process)) return 5;
    for (int attempt = 0; attempt < 100 && !target_state->alive; attempt++) pump(10);
    if (!target_state->alive) return 6;
    HWND overlay = make_window(L"Farm layered window probe", x, y, 320, 160, 1);
    pump(250);
    POINT previous_cursor; GetCursorPos(&previous_cursor);
    LONG baseline = target_state->clicks;
    int ok = 1;
    apply(overlay, 0); pump(100);
    ok &= click_at(x + 160, y + 80); pump(150);
    printf("OBSERVATION child_clicks=%ld overlay_clicks=%d\n", target_state->clicks, overlay_clicks);
    ok &= target_state->clicks > baseline && overlay_clicks == 0;
    LONG after_observation = target_state->clicks;
    apply(overlay, 1); pump(100);
    /* Observation activates the other process under ordinary Z ordering.
     * Explicitly select only this controlled test overlay before testing routing.
     * The foreground child grants its parent permission; the game itself never
     * asks another application for foreground permission or forces activation. */
    SendMessageW((HWND)target_state->hwnd, WM_APP + 1, GetCurrentProcessId(), 0);
    SetForegroundWindow(overlay);
    SetWindowPos(overlay, HWND_TOP, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    pump(100);
    ok &= click_at(x + 160, y + 80); pump(150);
    printf("INTERACTION child_clicks=%ld overlay_clicks=%d\n", target_state->clicks, overlay_clicks);
    ok &= target_state->clicks == after_observation && overlay_clicks >= 1;
    int after_interaction = overlay_clicks;
    apply(overlay, 0); pump(100);
    SetWindowPos(overlay, HWND_TOP, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    ok &= click_at(x + 160, y + 80); pump(150);
    printf("RETURN child_clicks=%ld overlay_clicks=%d\n", target_state->clicks, overlay_clicks);
    ok &= target_state->clicks > after_observation && overlay_clicks == after_interaction;
    SetCursorPos(previous_cursor.x, previous_cursor.y);
    DestroyWindow(overlay);
    PostMessageW((HWND)target_state->hwnd, WM_CLOSE, 0, 0);
    WaitForSingleObject(process.hProcess, 3000);
    CloseHandle(process.hThread); CloseHandle(process.hProcess);
    UnmapViewOfFile(target_state); CloseHandle(mapping); FreeLibrary(library);
    printf("CROSS_PROCESS_INPUT_%s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
