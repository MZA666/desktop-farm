#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    HWND window = (HWND)(uintptr_t)_strtoui64(argv[1], NULL, 10);
    DWORD_PTR result;
    if (!IsWindow(window)) return 3;
    if (!SendMessageTimeoutW(window, WM_POWERBROADCAST, PBT_APMSUSPEND, 0, SMTO_ABORTIFHUNG, 3000, &result)) return 4;
    Sleep(100);
    if (!SendMessageTimeoutW(window, WM_POWERBROADCAST, PBT_APMRESUMEAUTOMATIC, 0, SMTO_ABORTIFHUNG, 3000, &result)) return 5;
    printf("POWER_MESSAGES_SENT (synthetic; computer was not suspended)\n");
    return 0;
}
