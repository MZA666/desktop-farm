/* Reuse the controlled child/desktop guard; all camera input is real SendInput. */
#define wmain toolbar_fixture_main
#include "toolbar_input_probe.c"
#undef wmain

static int fixture_target(HWND hit, HWND expected, DWORD fixture_pid) {
    DWORD process_id = 0;
    GetWindowThreadProcessId(hit, &process_id);
    return IsWindow(hit) && hit == expected && process_id == fixture_pid;
}

static int wheel_at(int x, int y, int direction) {
    INPUT event = {0}; event.type = INPUT_MOUSE;
    event.mi.dwFlags = MOUSEEVENTF_WHEEL;
    event.mi.mouseData = (DWORD)(direction * WHEEL_DELTA);
    return SetCursorPos(x, y) && SendInput(1, &event, sizeof(event)) == 1;
}

int wmain(int argc, wchar_t **argv) {
    if (argc == 2 || (argc >= 5 && wcscmp(argv[1], L"--child") == 0))
        return toolbar_fixture_main(argc, argv);
    if (argc < 4) return 2;
    HWND toolbar = (HWND)(uintptr_t)_wcstoui64(argv[2], NULL, 10);
    HWND scenery = (HWND)(uintptr_t)_wcstoui64(argv[3], NULL, 10);
    DWORD fixture_pid = 0, scene_pid = 0;
    GetWindowThreadProcessId(toolbar, &fixture_pid);
    GetWindowThreadProcessId(scenery, &scene_pid);
    if (!fixture_pid || fixture_pid != scene_pid || !IsWindow(toolbar) || !IsWindow(scenery)) return 3;
    if (!desktop_available(1)) { puts("CAMERA_INPUT_DESKTOP_UNAVAILABLE"); return 12; }
    wchar_t mapping_name[128], executable[MAX_PATH], command[2048];
    swprintf(mapping_name, 128, L"Local\\DesktopFarmCameraProbe.%lu", GetCurrentProcessId());
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
    for (int attempt = 0; attempt < 200 && !target_state->ready; attempt++) pump(5);
    wchar_t request[2048], ack[2048], done[2048], ready[2048], details[2048];
    path_for(request, 2048, argv[1], L"step"); path_for(ack, 2048, argv[1], L"ack");
    path_for(done, 2048, argv[1], L"done"); path_for(ready, 2048, argv[1], L"ready");
    path_for(details, 2048, argv[1], L"details");
    FILE *start = _wfopen(ready, L"w"); if (start) { fputs("1", start); fclose(start); }
    POINT previous; GetCursorPos(&previous);
    int index = -1, ok = target_state->ready != 0;
    ULONGLONG deadline = GetTickCount64() + 300000;
    while (ok && GetTickCount64() < deadline && GetFileAttributesW(done) == INVALID_FILE_ATTRIBUTES) {
        if (!desktop_available(0)) { ok = 0; break; }
        int incoming = -1, x = 0, y = 0, kind = 0;
        FILE *file = _wfopen(request, L"r");
        if (file) { if (fscanf(file, "%d %d %d %d", &incoming, &x, &y, &kind) != 4) incoming = -1; fclose(file); }
        if (incoming <= index) { pump(5); continue; }
        index = incoming;
        HWND other = (HWND)target_state->hwnd;
        HWND before = GetForegroundWindow();
        if (kind == 0) {
            /* Each button is a real first click from another foreground app. */
            if (index == 0) {
                SetWindowPos(toolbar, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                SetWindowPos(other, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            }
            POINT other_point = {work.left + 110, work.top + 75};
            LONG baseline = target_state->clicks;
            ok &= fixture_target(WindowFromPoint(other_point), other, child.dwProcessId);
            if (ok) ok &= click_at(other_point.x, other_point.y);
            pump(100);
            if (index == 0) SetWindowPos(other, HWND_NOTOPMOST, 0, 0, 0, 0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            before = GetForegroundWindow();
            ok &= target_state->clicks > baseline && before == other;
        } else {
            /* Wheel follows an actual toolbar click, so the fixture already
             * has keyboard focus; no inactive-scroll OS setting is required. */
            ok &= (kind == 1 || kind == -1) && before == toolbar;
        }
        POINT point = {x, y}; HWND hit = WindowFromPoint(point);
        HWND expected = kind == 0 ? toolbar : scenery;
        ok &= fixture_target(hit, expected, fixture_pid);
        if (ok) ok &= kind == 0 ? click_at(x, y) : wheel_at(x, y, kind);
        pump(100);
        HWND foreground = GetForegroundWindow();
        ok &= foreground == toolbar;
        FILE *diagnostic = _wfopen(details, L"a");
        if (diagnostic) {
            fprintf(diagnostic, "step=%d kind=%d ok=%d fixture_pid=%lu x=%d y=%d expected=%llu hit=%llu before=%llu foreground=%llu\n",
                index, kind, ok, fixture_pid, x, y, (unsigned long long)(uintptr_t)expected,
                (unsigned long long)(uintptr_t)hit, (unsigned long long)(uintptr_t)before,
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
    printf("CAMERA_REAL_INPUT_%s steps=%d\n", ok ? "PASS" : "FAIL", index + 1);
    return ok ? 0 : 1;
}
