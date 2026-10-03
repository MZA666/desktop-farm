/* Real cross-process clicks against product Godot controls, never signal emission. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

typedef struct { volatile LONG ready; volatile LONG clicks; uintptr_t hwnd; } Shared;
static Shared *shared;

static int desktop_available(int report) {
    wchar_t name[128] = {0}, image[1024] = {0}, class_name[128] = {0}; DWORD needed = 0;
    HDESK desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    int unlocked = desktop && GetUserObjectInformationW(desktop, UOI_NAME,
        name, sizeof(name), &needed) && wcscmp(name, L"Default") == 0;
    if (desktop) CloseDesktop(desktop);
    HWND foreground = GetForegroundWindow(); DWORD pid = 0;
    GetWindowThreadProcessId(foreground, &pid);
    GetClassNameW(foreground, class_name, 128);
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (process) { DWORD size = 1024; QueryFullProcessImageNameW(process, 0, image, &size); CloseHandle(process); }
    const wchar_t *file = wcsrchr(image, L'\\'); file = file ? file + 1 : image;
    if (_wcsicmp(file, L"LockApp.exe") == 0 || _wcsicmp(file, L"LogonUI.exe") == 0 ||
            _wcsicmp(file, L"winlogon.exe") == 0) unlocked = 0;
    if (report) wprintf(L"INPUT_DESKTOP available=%d desktop=%ls foreground_pid=%lu foreground_image=%ls class=%ls\n",
        unlocked, name, pid, file, class_name);
    return unlocked;
}

static LRESULT CALLBACK probe_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_LBUTTONDOWN && shared) InterlockedIncrement(&shared->clicks);
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
        Sleep(3);
    } while (GetTickCount64() < until);
}

static int click_at(int x, int y) {
    INPUT input[2]; ZeroMemory(input, sizeof(input));
    input[0].type = input[1].type = INPUT_MOUSE;
    input[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    input[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    return SetCursorPos(x, y) && SendInput(2, input, sizeof(INPUT)) == 2;
}

static void path_for(wchar_t *out, size_t size, const wchar_t *prefix, const wchar_t *suffix) {
    swprintf(out, size, L"%ls.%ls", prefix, suffix);
}

static void write_ack(const wchar_t *path, int index, int ok, HWND hit, HWND foreground) {
    FILE *file = _wfopen(path, L"w");
    if (!file) return;
    fprintf(file, "%d %d %llu %llu\n", index, ok,
        (unsigned long long)(uintptr_t)hit, (unsigned long long)(uintptr_t)foreground);
    fclose(file);
}

int wmain(int argc, wchar_t **argv) {
    if (argc == 2 && wcscmp(argv[1], L"--desktop-status") == 0) return desktop_available(1) ? 0 : 12;
    if (argc >= 5 && wcscmp(argv[1], L"--child") == 0) {
        HANDLE mapping = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, argv[2]);
        if (!mapping) return 10;
        shared = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(Shared));
        if (!shared) return 11;
        WNDCLASSW cls = {0}; cls.lpfnWndProc = probe_proc; cls.hInstance = GetModuleHandleW(NULL);
        cls.lpszClassName = L"DesktopFarmToolbarInputTarget";
        cls.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1); RegisterClassW(&cls);
        HWND target = CreateWindowExW(WS_EX_TOOLWINDOW, cls.lpszClassName,
            L"Controlled other application", WS_POPUP, _wtoi(argv[3]), _wtoi(argv[4]),
            200, 90, NULL, NULL, cls.hInstance, NULL);
        shared->hwnd = (uintptr_t)target;
        ShowWindow(target, SW_SHOWNOACTIVATE);
        /* STARTF_USESHOWWINDOW intentionally starts the helper hidden; the
         * first ShowWindow inherits that flag, so reveal only its test HWND. */
        SetWindowPos(target, HWND_TOP, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
        InterlockedExchange(&shared->ready, 1);
        MSG msg;
        while (GetMessageW(&msg, NULL, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        UnmapViewOfFile(shared); CloseHandle(mapping); return 0;
    }
    if (argc < 3) return 2;
    HWND toolbar = (HWND)(uintptr_t)_wcstoui64(argv[2], NULL, 10);
    if (!IsWindow(toolbar)) return 3;
    if (!desktop_available(1)) { printf("TOOLBAR_INPUT_DESKTOP_UNAVAILABLE\n"); return 12; }
    wchar_t mapping_name[128], executable[MAX_PATH], command[2048];
    swprintf(mapping_name, 128, L"Local\\DesktopFarmToolbarProbe.%lu", GetCurrentProcessId());
    HANDLE mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, sizeof(Shared), mapping_name);
    Shared *target_state = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(Shared));
    if (!target_state) return 4;
    ZeroMemory(target_state, sizeof(Shared));
    RECT work; SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    GetModuleFileNameW(NULL, executable, MAX_PATH);
    swprintf(command, 2048, L"\"%ls\" --child %ls %d %d", executable, mapping_name, work.left + 40, work.top + 40);
    STARTUPINFOW startup = {0}; PROCESS_INFORMATION child = {0}; startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW; startup.wShowWindow = SW_HIDE;
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &child)) return 5;
    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limit = {0};
        limit.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limit, sizeof(limit)) ||
                !AssignProcessToJobObject(job, child.hProcess)) { CloseHandle(job); job = NULL; }
    }
    for (int i = 0; i < 200 && !target_state->ready; i++) pump(5);
    wchar_t request[2048], ack[2048], done[2048], ready[2048], details[2048];
    path_for(request, 2048, argv[1], L"step"); path_for(ack, 2048, argv[1], L"ack");
    path_for(done, 2048, argv[1], L"done"); path_for(ready, 2048, argv[1], L"ready");
    path_for(details, 2048, argv[1], L"details");
    FILE *start = _wfopen(ready, L"w"); if (start) { fputs("1", start); fclose(start); }
    POINT previous; GetCursorPos(&previous);
    int index = -1, ok = target_state->ready != 0;
    ULONGLONG deadline = GetTickCount64() + 300000;
    while (ok && GetTickCount64() < deadline && GetFileAttributesW(done) == INVALID_FILE_ATTRIBUTES) {
        if (!desktop_available(0)) { printf("INPUT_DESKTOP_BECAME_UNAVAILABLE\n"); ok = 0; break; }
        int incoming = -1, x = 0, y = 0;
        FILE *file = _wfopen(request, L"r");
        if (file) { if (fscanf(file, "%d %d %d", &incoming, &x, &y) != 3) incoming = -1; fclose(file); }
        if (incoming <= index) { pump(5); continue; }
        index = incoming;
        LONG baseline = target_state->clicks;
        HWND other = (HWND)target_state->hwnd;
        /* Make only our controlled target reachable for the initial setup
         * click, then immediately return it to normal application priority. */
        if (index == 0) {
            /* A player's already running release can occupy the same bottom
             * strip. Raise only this fixture once within ordinary Z order,
             * without activation; all measured clicks start from the other
             * application's real foreground click below. Never move, hide,
             * activate or otherwise modify the player's release HWND. */
            SetWindowPos(toolbar, HWND_TOP, 0, 0, 0, 0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            SetWindowPos(other, HWND_TOPMOST, 0, 0, 0, 0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
        POINT other_point = {work.left + 110, work.top + 75};
        HWND other_hit = WindowFromPoint(other_point);
        ok &= other_hit == other;
        if (ok) ok &= click_at(work.left + 110, work.top + 75);
        pump(100);
        if (index == 0) SetWindowPos(other, HWND_NOTOPMOST, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        HWND after_other = GetForegroundWindow();
        /* Native activation can replay the controlled target's mouse message;
         * its count proves routing, while Godot button count proves one action. */
        ok &= target_state->clicks > baseline && after_other == other;
        POINT button = {x, y}; HWND hit = WindowFromPoint(button);
        ok &= hit == toolbar;
        if (ok) ok &= click_at(x, y);
        pump(100);
        HWND foreground = GetForegroundWindow();
        ok &= foreground == toolbar;
        FILE *diagnostic = _wfopen(details, L"a");
        if (diagnostic) {
            fprintf(diagnostic, "round=%d ok=%d other=%llu other_hit=%llu other_foreground=%llu other_clicks=%ld baseline=%ld toolbar=%llu toolbar_hit=%llu toolbar_foreground=%llu\n",
                index, ok, (unsigned long long)(uintptr_t)other, (unsigned long long)(uintptr_t)other_hit,
                (unsigned long long)(uintptr_t)after_other, target_state->clicks, baseline,
                (unsigned long long)(uintptr_t)toolbar, (unsigned long long)(uintptr_t)hit,
                (unsigned long long)(uintptr_t)foreground);
            fclose(diagnostic);
        }
        write_ack(ack, index, ok, hit, foreground);
    }
    if (GetFileAttributesW(done) == INVALID_FILE_ATTRIBUTES) ok = 0;
    SetCursorPos(previous.x, previous.y);
    PostMessageW((HWND)target_state->hwnd, WM_CLOSE, 0, 0);
    WaitForSingleObject(child.hProcess, 2000);
    CloseHandle(child.hThread); CloseHandle(child.hProcess);
    if (job) CloseHandle(job);
    UnmapViewOfFile(target_state); CloseHandle(mapping);
    printf("TOOLBAR_REAL_CLICK_%s rounds=%d\n", ok ? "PASS" : "FAIL", index + 1);
    return ok ? 0 : 1;
}
