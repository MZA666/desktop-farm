/* Controlled foreground app switches between a normal maximized window and
 * borderless whole-monitor fullscreen. File handshakes let the Godot host
 * verify visibility at every transition without racing arbitrary sleeps. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

typedef struct { volatile LONG ready; volatile LONG command; volatile LONG completed; uintptr_t hwnd; } Shared;
static Shared *shared;

static LRESULT CALLBACK probe_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void pump(DWORD duration) {
    ULONGLONG end = GetTickCount64() + duration;
    MSG msg;
    do {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        Sleep(5);
    } while (GetTickCount64() < end);
}

static int write_phase(const wchar_t *prefix, const wchar_t *suffix, int phase) {
    wchar_t path[1024]; swprintf(path, 1024, L"%ls.%ls", prefix, suffix);
    FILE *file = _wfopen(path, L"w"); if (!file) return 0;
    fprintf(file, "%d", phase); fclose(file); return 1;
}

static int read_phase(const wchar_t *prefix, const wchar_t *suffix) {
    wchar_t path[1024]; swprintf(path, 1024, L"%ls.%ls", prefix, suffix);
    FILE *file = _wfopen(path, L"r"); if (!file) return 0;
    int phase = 0; fscanf(file, "%d", &phase); fclose(file); return phase;
}

int wmain(int argc, wchar_t **argv) {
    if (argc >= 3 && wcscmp(argv[1], L"--child") == 0) {
        HANDLE mapping = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, argv[2]);
        if (!mapping) return 10;
        shared = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(Shared));
        WNDCLASSW cls = {0}; cls.lpfnWndProc = probe_proc; cls.hInstance = GetModuleHandleW(NULL);
        cls.lpszClassName = L"DesktopFarm.FullscreenAcceptance"; cls.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
        RegisterClassW(&cls);
        HWND window = CreateWindowExW(WS_EX_TOOLWINDOW, cls.lpszClassName,
            L"Farm fullscreen acceptance test - closes automatically", WS_OVERLAPPEDWINDOW,
            60, 60, 640, 480, NULL, NULL, cls.hInstance, NULL);
        ShowWindow(window, SW_SHOWNOACTIVATE); shared->hwnd = (uintptr_t)window;
        InterlockedExchange(&shared->ready, 1);
        int last = 0;
        while (IsWindow(window)) {
            int command = shared->command;
            if (command != last) {
                if (command == 1) {
                    ShowWindow(window, SW_RESTORE);
                    SetWindowLongPtrW(window, GWL_STYLE, WS_OVERLAPPEDWINDOW);
                    SetWindowPos(window, NULL, 0, 0, 0, 0,
                        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
                    ShowWindow(window, SW_MAXIMIZE);
                } else if (command == 2) {
                    ShowWindow(window, SW_RESTORE);
                    SetWindowLongPtrW(window, GWL_STYLE, WS_POPUP);
                    MONITORINFO monitor = {0}; monitor.cbSize = sizeof(monitor);
                    GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTOPRIMARY), &monitor);
                    RECT rect = monitor.rcMonitor;
                    SetWindowPos(window, NULL, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top,
                        SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
                }
                last = command; InterlockedExchange(&shared->completed, command);
            }
            pump(5);
        }
        UnmapViewOfFile(shared); CloseHandle(mapping); return 0;
    }
    if (argc != 2) return 2;
    wchar_t map_name[128], executable[MAX_PATH], command[1024];
    swprintf(map_name, 128, L"Local\\FarmFullscreenProbe.%lu", GetCurrentProcessId());
    HANDLE mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, sizeof(Shared), map_name);
    Shared *state = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(Shared));
    ZeroMemory(state, sizeof(Shared)); GetModuleFileNameW(NULL, executable, MAX_PATH);
    swprintf(command, 1024, L"\"%ls\" --child %ls", executable, map_name);
    STARTUPINFOW startup = {0}; PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup); startup.dwFlags = STARTF_USESHOWWINDOW; startup.wShowWindow = SW_HIDE;
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &process)) return 3;
    for (int count = 0; count < 200 && !state->ready; count++) pump(5);
    HWND target = (HWND)state->hwnd;
    POINT cursor; GetCursorPos(&cursor);
    /* Protect the initial real click from unrelated pre-existing overlays.
     * Only this controlled test window is promoted, then immediately returned
     * to normal Z order after activation; no player HWND is modified. */
    SetWindowPos(target, HWND_TOPMOST, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    pump(80);
    RECT rect; GetWindowRect(target, &rect); SetCursorPos(rect.left + 100, rect.top + 80);
    INPUT inputs[2] = {0}; inputs[0].type = inputs[1].type = INPUT_MOUSE;
    inputs[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN; inputs[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    int ok = state->ready && SendInput(2, inputs, sizeof(INPUT)) == 2;
    pump(100);
    ok &= GetForegroundWindow() == target;
    wchar_t detail_path[1024]; swprintf(detail_path, 1024, L"%ls.details", argv[1]);
    FILE *details = _wfopen(detail_path, L"w");
    if (details) {
        fprintf(details, "ready=%ld visible=%d foreground_match=%d target=%llu foreground=%llu input_ok=%d\n",
            state->ready, IsWindowVisible(target), GetForegroundWindow() == target,
            (unsigned long long)(uintptr_t)target, (unsigned long long)(uintptr_t)GetForegroundWindow(), ok);
        fclose(details);
    }
    SetWindowPos(target, HWND_NOTOPMOST, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    for (int phase = 1; phase <= 7 && ok; phase++) {
        int desired = phase % 2 ? 1 : 2;
        InterlockedExchange(&state->command, desired);
        for (int count = 0; count < 200 && state->completed != desired; count++) pump(5);
        pump(120); // Allow DWM's frame geometry to settle after a style change.
        ok &= write_phase(argv[1], L"phase", phase);
        int acknowledged = 0;
        for (int count = 0; count < 500 && !acknowledged; count++) {
            acknowledged = read_phase(argv[1], L"ack") == phase; pump(10);
        }
        ok &= acknowledged && GetForegroundWindow() == target;
    }
    write_phase(argv[1], L"result", ok ? 1 : -1);
    printf("FULLSCREEN_FOREGROUND_%s\n", ok ? "PASS" : "FAIL");
    SetCursorPos(cursor.x, cursor.y); PostMessageW(target, WM_CLOSE, 0, 0);
    WaitForSingleObject(process.hProcess, 3000); CloseHandle(process.hThread); CloseHandle(process.hProcess);
    UnmapViewOfFile(state); CloseHandle(mapping); return ok ? 0 : 1;
}
