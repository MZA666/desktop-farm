#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    HWND shell = (HWND)(uintptr_t)_strtoui64(argv[1], NULL, 10);
    if (!IsWindow(shell) || IsWindowVisible(shell)) return 3;
    /* The fixture owns this separate test shortcut; Ctrl+Alt+F remains untouched.
     * Windows must deliver the registered hotkey from actual keyboard input. */
    INPUT inputs[8] = {0};
    WORD keys[8] = {VK_CONTROL, VK_MENU, VK_SHIFT, VK_F12, VK_F12, VK_SHIFT, VK_MENU, VK_CONTROL};
    for (int i = 0; i < 8; i++) {
        inputs[i].type = INPUT_KEYBOARD;
        inputs[i].ki.wVk = keys[i];
        inputs[i].ki.dwFlags = i >= 4 ? KEYEVENTF_KEYUP : 0;
    }
    if (SendInput(8, inputs, sizeof(INPUT)) != 8) return 4;
    for (int action = 1; action <= 5; action++) {
        if (!PostMessageW(shell, WM_COMMAND, 0xD100 + action, 0)) return 5;
        Sleep(50);
    }
    /* Exercise the actual native tray context menu, rather than treating
     * command dispatch alone as proof that TrackPopupMenu can display. */
    if (!PostMessageW(shell, WM_APP + 61, 0, MAKELPARAM(WM_CONTEXTMENU, 1))) return 6;
    GUITHREADINFO info = {0}; info.cbSize = sizeof(info);
    DWORD thread = GetWindowThreadProcessId(shell, NULL);
    int opened = 0;
    for (int count = 0; count < 40 && !opened; count++) {
        Sleep(10);
        opened = GetGUIThreadInfo(thread, &info) && (info.flags & GUI_INMENUMODE) && info.hwndMenuOwner == shell;
    }
    FILE *report = fopen(argv[2], "w");
    if (report) { fprintf(report, "%d", opened); fclose(report); }
    PostMessageW(shell, WM_CANCELMODE, 0, 0);
    return opened ? 0 : 7;
}
