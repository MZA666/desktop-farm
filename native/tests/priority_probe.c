/* Real mouse activation of a controlled window owned by a different process.
 * Also accepts actual Godot HWNDs to verify host settings/layout regressions. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

typedef struct { volatile LONG ready; volatile LONG clicks; uintptr_t hwnd; } Shared;
static Shared *shared;

static LRESULT CALLBACK probe_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_LBUTTONDOWN && shared) { InterlockedIncrement(&shared->clicks); return 0; }
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(hwnd, msg, wp, lp);
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

static HWND create_window(const wchar_t *title, RECT rect, int topmost) {
    WNDCLASSW cls = {0};
    cls.lpfnWndProc = probe_proc; cls.hInstance = GetModuleHandleW(NULL);
    cls.lpszClassName = L"DesktopFarmPriorityProbe";
    cls.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassW(&cls);
    HWND window = CreateWindowExW(WS_EX_TOOLWINDOW | (topmost ? WS_EX_TOPMOST : 0),
        cls.lpszClassName, title, WS_POPUP, rect.left, rect.top,
        rect.right - rect.left, rect.bottom - rect.top, NULL, NULL, cls.hInstance, NULL);
    ShowWindow(window, SW_SHOWNA);
    SetWindowPos(window, NULL, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    return window;
}

static int is_above(HWND front, HWND back) {
    for (HWND current = GetTopWindow(NULL); current; current = GetWindow(current, GW_HWNDNEXT)) {
        if (current == front) return 1;
        if (current == back) return 0;
    }
    return 0;
}

static int click_at(int x, int y) {
    if (!SetCursorPos(x, y)) return 0;
    INPUT inputs[2] = {0};
    inputs[0].type = inputs[1].type = INPUT_MOUSE;
    inputs[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    inputs[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    return SendInput(2, inputs, sizeof(INPUT)) == 2;
}

int wmain(int argc, wchar_t **argv) {
    if (argc >= 3 && wcscmp(argv[1], L"--child") == 0) {
        HANDLE mapping = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, argv[2]);
        if (!mapping) return 10;
        shared = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(Shared));
        RECT work; SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
        RECT rect = {work.left + 60, work.top + 60, work.left + 500, work.bottom - 40};
        HWND target = create_window(L"Controlled foreground application", rect, 0);
        shared->hwnd = (uintptr_t)target; InterlockedExchange(&shared->ready, 1);
        MSG msg;
        while (GetMessageW(&msg, NULL, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        UnmapViewOfFile(shared); CloseHandle(mapping); return 0;
    }
    int external = argc >= 5 && wcscmp(argv[1], L"--handles") == 0;
    if (!external && argc < 2) return 2;
    HWND games[3] = {0}; int game_count = 2, ok = 1;
    HMODULE library = NULL;
    typedef int (*NormalWindow)(HWND);
    typedef int (*ShowWindowNoRaise)(HWND);
    typedef int (*ApplyStyle)(HWND, int);
    NormalWindow normal = NULL; ShowWindowNoRaise show = NULL; ApplyStyle apply = NULL;
    if (external) {
        game_count = argc - 3; if (game_count > 3) game_count = 3;
        for (int i = 0; i < game_count; i++) games[i] = (HWND)(uintptr_t)_wcstoui64(argv[i + 3], NULL, 10);
    } else {
        library = LoadLibraryW(argv[1]); if (!library) return 3;
        normal = (NormalWindow)(void *)GetProcAddress(library, "desktop_make_normal_window");
        show = (ShowWindowNoRaise)(void *)GetProcAddress(library, "desktop_show_without_raise");
        apply = (ApplyStyle)(void *)GetProcAddress(library, "desktop_apply_style");
        if (!normal || !show || !apply) return 4;
        RECT work; SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
        RECT scenery = {work.left, work.bottom - 200, work.right, work.bottom};
        RECT toolbar = {work.left, work.bottom - 232, work.right, work.bottom - 200};
        games[0] = create_window(L"Controlled farm scenery", scenery, 1);
        games[1] = create_window(L"Controlled farm toolbar", toolbar, 1);
        ok &= apply(games[0], 0) && normal(games[1]);
    }
    for (int i = 0; i < game_count; i++) {
        ok &= IsWindow(games[i]) && !(GetWindowLongPtrW(games[i], GWL_EXSTYLE) & WS_EX_TOPMOST);
    }
    wchar_t mapping_name[128], executable[MAX_PATH], command[1024];
    swprintf(mapping_name, 128, L"Local\\FarmPriorityProbe.%lu", GetCurrentProcessId());
    HANDLE mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, sizeof(Shared), mapping_name);
    Shared *state = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(Shared));
    ZeroMemory(state, sizeof(Shared)); GetModuleFileNameW(NULL, executable, MAX_PATH);
    swprintf(command, 1024, L"\"%ls\" --child %ls", executable, mapping_name);
    STARTUPINFOW startup = {0}; PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup); startup.dwFlags = STARTF_USESHOWWINDOW; startup.wShowWindow = SW_HIDE;
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &process)) return 5;
    for (int attempt = 0; attempt < 100 && !state->ready; attempt++) pump(10);
    if (!state->ready) return 6;
    HWND target = (HWND)state->hwnd;
    if (!external) {
        for (int i = 0; i < game_count; i++) SetWindowPos(games[i], HWND_TOP, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
    /* Expose the controlled application's click point. SW_SHOWNA may place
     * a new background process behind an unrelated foreground app. This
     * changes visibility only; activation still must come from real input. */
    SetWindowPos(target, HWND_TOP, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    POINT cursor; GetCursorPos(&cursor); RECT target_rect; GetWindowRect(target, &target_rect);
    pump(100); int injected = click_at(target_rect.left + 30, target_rect.top + 30); ok &= injected; pump(200);
    int focused = GetForegroundWindow() == target && state->clicks > 0;
    POINT actual_cursor = {0}; GetCursorPos(&actual_cursor);
    DWORD hit_pid = 0, foreground_pid = 0, target_pid = 0;
    GetWindowThreadProcessId(WindowFromPoint(actual_cursor), &hit_pid);
    GetWindowThreadProcessId(GetForegroundWindow(), &foreground_pid);
    GetWindowThreadProcessId(target, &target_pid);
    int initial_above[3] = {0}, final_above[3] = {0};
    ok &= focused;
    for (int i = 0; i < game_count; i++) { initial_above[i] = is_above(target, games[i]); ok &= initial_above[i]; }
    if (!external) {
        for (int cycle = 0; cycle < 3; cycle++) {
            ok &= apply(games[0], cycle % 2) && normal(games[1]);
            ok &= show(games[0]) && show(games[1]);
            SetWindowPos(games[1], NULL, 0, 0, 0, 0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
            pump(30);
        }
    }
    pump(2200); // The Godot host refreshes settings and geometry during this interval.
    int foreground_retained = GetForegroundWindow() == target;
    ok &= foreground_retained;
    for (int i = 0; i < game_count; i++) {
        final_above[i] = is_above(target, games[i]); ok &= final_above[i];
        ok &= !(GetWindowLongPtrW(games[i], GWL_EXSTYLE) & WS_EX_TOPMOST);
    }
    printf("PRIORITY_%s windows=%d real_click=%d foreground_retained=%d\n", ok ? "PASS" : "FAIL",
        game_count, focused, foreground_retained);
    if (external) {
        wchar_t diagnostic_path[1024];
        swprintf(diagnostic_path, 1024, L"%ls.diagnostics", argv[2]);
        FILE *diagnostic = _wfopen(diagnostic_path, L"w");
        if (diagnostic) {
            fprintf(diagnostic, "input_injected=%d target_clicks=%ld focused=%d retained=%d initial_above=%d,%d,%d final_above=%d,%d,%d cursor=%ld,%ld target=%ld,%ld,%ld,%ld hit_pid=%lu foreground_pid=%lu target_pid=%lu\n", injected, state->clicks, focused, foreground_retained, initial_above[0], initial_above[1], initial_above[2], final_above[0], final_above[1], final_above[2], actual_cursor.x, actual_cursor.y, target_rect.left, target_rect.top, target_rect.right, target_rect.bottom, hit_pid, foreground_pid, target_pid);
            fclose(diagnostic);
        }
        FILE *report = _wfopen(argv[2], L"w");
        if (!report) ok = 0;
        else { fprintf(report, "%d", ok); fclose(report); }
    }
    SetCursorPos(cursor.x, cursor.y); PostMessageW(target, WM_CLOSE, 0, 0);
    WaitForSingleObject(process.hProcess, 3000); CloseHandle(process.hThread); CloseHandle(process.hProcess);
    UnmapViewOfFile(state); CloseHandle(mapping);
    if (!external) { for (int i = 0; i < game_count; i++) DestroyWindow(games[i]); FreeLibrary(library); }
    return ok ? 0 : 1;
}
