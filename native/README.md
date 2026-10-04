# Windows desktop bridge

This module uses the official Godot GDExtension C interface and Windows APIs; it does not require `godot-cpp`, Visual Studio installation, or .NET. The build uses the portable Zig compiler pinned in `.tools/toolchain.json`. `desktop_native.gdextension` loads `bin/desktop_native.dll` on Windows x64; the minimum Godot version is 4.4.

Build from the project directory (the bridge also links the system `shell32` and `gdi32` libraries for tray UI):

```powershell
./native/build.ps1
./native/build_tests.ps1
```

The camera regression probe uses an isolated actual main scene and real mouse
clicks/wheel, guarded by expected HWND and fixture process ID:

```powershell
& ./.tools/godot-4.7.2-stable/Godot_v4.7.2-stable_win64_console.exe --path . --log-file .review/camera-input.log --script res://native/tests/test_camera_input.gd -- --benchmark-fixture
```

It covers 32px arrows, 16px wheel steps, centering, height/scene memory including
clamped extremes, 640px toolbar reach, and no transparent gaps at world edges.
An unlocked desktop is required; it never injects input into a player's game.

`DesktopHost.start(scene_window, toolbar_window, settings)` converts the scenery's Godot window ID to a native HWND and attaches `DesktopNative`. The scenery receives `WS_EX_LAYERED`, `WS_EX_NOACTIVATE`, and `WS_EX_TOOLWINDOW`; observation mode adds `WS_EX_TRANSPARENT`, and interaction removes it. The Godot root window is the clickable toolbar and receives `WS_EX_APPWINDOW`; scenery and management panels are owned tool windows without their own taskbar/Alt+Tab entry. `WM_MOUSEACTIVATE` on the toolbar returns `MA_ACTIVATE`, so a real first click activates it and reaches Godot. The bridge uses `SetWindowSubclass` rather than replacing the Godot window procedure, and scenery routing does not rely on Godot's mouse passthrough flag.

`get_work_area()` returns the current monitor's `rcWork` as a `Rect2i`, excluding the taskbar. `get_dpi_scale()` returns `GetDpiForWindow(hwnd) / 96`. Layout uses physical window coordinates and informs the UI when the work area or scale changes. `try_single_instance()` retains a per-session named mutex until `release()` or process exit.

Collapsing uses native `set_visible(false)` / `ShowWindow(SW_HIDE)` on the owned scenery. Its independent rendering viewport is disabled while the root toolbar, scene tree, and clock remain active. Expansion restores scenery with `SW_SHOWNA`. The physical scenery rectangle starts below the toolbar rectangle: ownership never lets a transparent scene surface cover the toolbar's input region. Scene and management viewports use `viewport_set_parent_viewport(rid, RID())` to render independently of root visibility. Ownership and rendering independence are separate settings. Showing an already-visible HWND is a no-op, so visibility/settings polling does not activate or raise windows. `is_visible()` and `window_is_visible(hwnd)` report actual `IsWindowVisible` state for acceptance checks.

## Root toolbar and real first-click regression, v0.8.2

Verified on 2026-10-03 using Windows 11, Godot 4.7.2, Intel Iris Xe, and 100% DPI. `test_toolbar_input.gd -- --benchmark-fixture` loaded the actual `main.tscn` and completed 100 real cross-process mouse rounds. Each round first clicked a controlled external app and checked its foreground HWND, then clicked one actual farm/ranch/pond toolbar button once. It checked the target HWND, toolbar foreground, exactly one Godot `Button.pressed` notification, and the resulting scene. No tested action uses `pressed.emit()` or synthetic Godot input.

The five groups cover expanded interaction, expanded observation, compact interaction, collapsed observation, and management-panel open/close followed by a first toolbar click. Every round also checks root/owned styles, scene ownership, enabled toolbar state, and non-overlapping production geometry. After final toolbar controls were parented to the main scene node, the complete test was rerun: evidence is `.review/toolbar-input-16612.details` and `.review/toolbar-input-16612.json` (`passed=true`, `rounds=100`). An already-running v0.8.1 player's toolbar overlapped the default test strip and caused an earlier round-0 fixture obstruction. The final test moves only its own windows to a separate test strip after checking production geometry, leaving that player process and saves untouched; the helper aborts rather than clicking an unexpected HWND.

The updated priority, fullscreen, tray, collapse, and rendering suites all passed with the root toolbar/owned scene architecture. Seven real fullscreen transitions retained external-app foreground and preserved user-hidden/collapsed/closed-panel state; the clock advanced 735 ms while suppressed. Collapsed scenery remained hidden while the root toolbar's actual rendered pixels changed, and the awake clock advanced 908 ms. The native HWND/style and synthetic suspend/resume save-callback suite also passed. The current DLL's real cross-process routing probe again passed observation target2/overlay0, interaction2/1, and return3/1. Actual system sleep, mixed-DPI hardware transitions, and physical monitor removal remain manual acceptance checks.

`test_minimize_restore.gd` sends native minimize/restore commands through Godot's root window mode and passed 326 checks. Its `--actual-main-fixture` mode loads the actual final `main.tscn`, toolbar controls, and settings panel; this also passed all 326 checks after the final UI hierarchy change (`.review/v082-minimize-final-hierarchy.log`). It first reproduced a polling bug: Windows hid owned windows on minimization, but the host's next visibility refresh showed them again. The fix includes the root's minimized state in content visibility while preserving the root's visible native taskbar entry. Root/scenery/panel rendering is suspended, the awake clock continues, and restoring preserves expanded/collapsed/closed-panel intent. The affected priority, fullscreen, and collapse-render suites were rerun and passed. This tests native window states rather than a physical mouse click on the Windows taskbar. Windows' owned-window minimize behavior is documented in [Window Features](https://learn.microsoft.com/en-us/windows/win32/winmsg/window-features#owned-windows).

```powershell
& .\.tools\godot-4.7.2-stable\Godot_v4.7.2-stable_win64_console.exe --path . --script res://native/tests/test_toolbar_input.gd -- --benchmark-fixture
& .\.tools\godot-4.7.2-stable\Godot_v4.7.2-stable_win64_console.exe --path . --script res://native/tests/test_minimize_restore.gd -- --benchmark-fixture
& .\.tools\godot-4.7.2-stable\Godot_v4.7.2-stable_win64_console.exe --path . --script res://native/tests/test_minimize_restore.gd -- --benchmark-fixture --actual-main-fixture
```

## Window priority correction, 2026-10-01

The scenery, toolbar, and purchase panels follow normal Windows Z order. `project.godot` starts without `always_on_top`; `DesktopHost` ignores legacy `topmost=true` settings and its legacy `set_topmost()` API always keeps ordinary priority. Native attachment and independent-window setup defensively demote existing `WS_EX_TOPMOST` windows. Repeated demotion is skipped when the flag is already absent, because calling `SetWindowPos(HWND_NOTOPMOST)` unnecessarily can move an ordinary window within its normal Z band. The monitor/layout loop does not activate or raise windows, and unchanged geometry avoids unnecessary native setter calls.

The new `test_window_priority.gd` launched three real Godot HWNDs plus a controlled foreground app in another process. A real mouse click activated that app; it remained above all three game windows while the host repeatedly refreshed old `topmost=true` settings, switched input modes, refreshed visibility, moved the scenery/toolbar by eight physical pixels, and recomputed layout. Result: `HOST_WINDOW_PRIORITY_PASS`. The standalone `priority_probe.exe desktop_native.dll` also verifies that initially topmost controlled HWNDs are demoted and repeated native style/show calls leave the foreground app above them.

The mouse-routing probe explicitly activates its controlled overlay before the interaction phase, with permission from its controlled foreground child. This is test setup after observation has naturally brought the other process to the front; the product never requests another app's foreground permission. Actual routing still passes observation: target 2 / overlay 0, interaction: target 2 / overlay 1, return: target 3 / overlay 1. Collapse visibility and the awake clock (907 ms while hidden), actual collapsed toolbar pixel updates, and synthetic suspend/resume callbacks were rerun successfully after the priority correction. No user's unrelated application or actual system sleep was used in these tests.

## Desktop shell and fullscreen visibility, v0.7

`DesktopHost.tray_action(action: String)` emits `toggle_visibility`, `toggle_interactive`, `open_seed_shop`, `open_animal_shop`, or `quit`. The Windows tray menu provides these actions; double-clicking the icon and the default Ctrl+Alt+F shortcut both emit `toggle_visibility`. The main controller decides how to persist input settings, open shops, and save before quitting. Native notifications are deferred by the host so UI changes and quitting happen after the Windows callback returns. The tray uses an original 32px pixel sprout icon created in memory, and an invisible zero-size native message window. No shell message window is shown as desktop content.

`set_user_hidden(bool)` and `toggle_user_hidden()` hide or show the entire scenery/toolbar/popup group for the current session. This state is deliberately separate from persisted `collapsed`, which hides scenery while retaining the toolbar. The controller calls `register_auxiliary_window(popup)` after constructing its popup. `is_desktop_visible()` describes whether content is currently allowed to appear, and `desktop_visibility_changed(visible: bool, reason: String)` reports `user_hidden`, `fullscreen`, `minimized`, or `visible`. `refresh_desktop_visibility()` updates this state immediately; otherwise the host checks every quarter second. The main controller can suspend visual animation while leaving production running. A minimized owner retains its taskbar entry even while its owned content is suppressed.

When another process's foreground window covers the farm monitor's entire physical monitor rectangle, the host hides all registered HWNDs and suspends their viewports. A normal maximized window with a title bar, the desktop/taskbar, an iconic window, a DWM-cloaked window, another monitor's fullscreen window, and this process's own windows are excluded. Exiting fullscreen restores the session's intended state: manual hiding wins, collapsed scenery stays collapsed, and a previously closed popup stays closed. Native hiding does not change `Window.visible`, so an open popup can be restored with `SW_SHOWNA` without activating it. The viewport cache tracks logical visibility and native window IDs, including closing/recreating popup HWNDs, to avoid duplicate rendering activation.

Ctrl+Alt+F registration failure is reported through `status_changed` with the Windows error code and tray/toolbar alternatives. If both tray and shortcut are unavailable, session hiding is refused to preserve a usable return path. `release()` removes only this instance's tray icon and registered hotkey, destroys its message window/icon, and releases its singleton. Explorer's `TaskbarCreated` message reinstalls the icon after a shell restart.

The explicit `--benchmark-fixture` user argument switches the host to a per-process test singleton namespace and leaves the player's Ctrl+Alt+F untouched. Direct shell acceptance tests use a separate Ctrl+Alt+Shift+F12 shortcut. No test exits or rewrites a player's running instance. The singleton API test requires the fixture flag and safely exits with code 2 if it is missing. Native test checks use failure-aware verification and nonzero exit codes instead of assertions that can leave a test's scene loop running.

Recorded on 2026-10-01, Godot 4.7.2, Zig 0.16.0, Windows 11/Iris Xe at 100% physical DPI:

| Check | Result |
| --- | --- |
| Tray added; actual native context menu enters the Windows menu loop; message sink remains invisible | Passed |
| Actual keyboard input triggers the registered isolated shortcut; six notifications map to deferred host signals | Passed |
| Duplicate shortcut reports Win32 1409; releasing one instance permits the second to register | Passed |
| Session hide/show applies to scenery and toolbar | Passed |
| Seven real cross-process maximized/fullscreen transitions hide all three game HWNDs, preserve session/collapse/popup state, and retain the external app's foreground | Passed |
| Closed/reopened popup HWND refreshes the viewport cache without Godot rendering errors | Passed |
| Awake clock continues during fullscreen suppression | Passed; 735 ms observed while suppressed |
| Synthetic negative/above-monitor geometry and 100/150/200% physical-DPI sizing/clamping, including a very short work area | Passed |
| Actual mixed-DPI hardware transitions and monitor removal | Manual hardware acceptance remains |

Run the isolated acceptance scripts from the workspace:

```powershell
& .\.tools\godot-4.7.2-stable\Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://native/tests/test_native.gd -- --benchmark-fixture
& .\.tools\godot-4.7.2-stable\Godot_v4.7.2-stable_win64_console.exe --path . --script res://native/tests/test_desktop_shell.gd -- --benchmark-fixture
& .\.tools\godot-4.7.2-stable\Godot_v4.7.2-stable_win64_console.exe --path . --script res://native/tests/test_fullscreen_visibility.gd -- --benchmark-fixture
& .\.tools\godot-4.7.2-stable\Godot_v4.7.2-stable_win64_console.exe --headless --path . --script res://native/tests/test_monitor_restore.gd
```

The fullscreen helper uses a controlled window in a second process and file handshakes for each transition. It protects only its own initial click from unrelated overlays, then immediately returns that test window to ordinary Z order; player windows are untouched. `.review/fullscreen-host.details` records `ready=1 visible=1 foreground_match=1`, and `.review/fullscreen-host.result` records `1`. The tray menu result is `.review/tray-menu-result.txt`, also `1`. These fixtures exercise actual Windows windows/menu/keyboard input but do not put the computer to sleep or change real display settings.

Saved positions are matched against every monitor's usable rectangle, including negative or vertically offset desktop coordinates, before clamping. The scenery is fitted inside the chosen monitor before querying its work area and DPI; points on a removed monitor fall back to the primary monitor. The supplied `test_monitor_restore.gd` verifies monitor selection with synthetic rectangles; actual display/DPI transitions remain a hardware acceptance check.

`elapsed_awake_msec()` returns `QueryUnbiasedInterruptTime` converted to milliseconds. This monotonic Windows clock excludes sleep and hibernation. `DesktopHost.consume_elapsed_msec()` measures differences only while this process is running; starting, explicit pause changes, and resume reset its anchor. Hiding the scenery does not pause production.

`WM_POWERBROADCAST` is observed with `SetWindowSubclass`. On `PBT_APMSUSPEND`, the native bridge invokes the registered save callable synchronously on the window thread before returning to Windows. The host emits `suspend_requested`; the application connects it to the save function. The callback must finish promptly and should only persist already committed state. `power_epoch()` and `suspend_epoch()` expose transitions; resumption clears `is_suspended()`.

## Verification recorded on 2026-09-30

Compiler: Zig 0.16.0, Windows x64 GNU C target; engine: Godot 4.7.2 stable, OpenGL Compatibility on Intel Iris Xe. Native DLL compilation completed without compiler warnings.

| Check | Result | Command |
| --- | --- | --- |
| C ABI object creation and cleanup, single instance lock/release, work area, monotonic awake clock, invalid handle safety | Passed | Godot `--headless --path . --script res://native/tests/test_native.gd` |
| Actual mouse input between two independently owned process windows, observation → interaction → observation | Passed | `native/bin/click_probe.exe native/bin/desktop_native.dll` (pass an absolute DLL path) |
| Actual Godot HWND attachment, extended style toggle, synchronous saving during synthetic suspend, resume flags | Passed | Godot `--path . --script res://native/tests/test_native_window.gd` |
| Native main window hide/restore, independent toolbar native visibility, clock progression while collapsed | Passed | Godot `--path . --script res://native/tests/test_collapse.gd` |
| Actual toolbar pixels update while main HWND is hidden and its rendering viewport is inactive | Passed | Godot `--path . --script res://native/tests/test_collapse_render.gd` |
| Saved monitor coordinate selection with negative/above-screen coordinates and missing monitor fallback | Passed | Godot `--headless --path . --script res://native/tests/test_monitor_restore.gd` |

The cross-process probe sends real mouse input to controlled test windows and restores the cursor afterward. Its recorded counts were observation: target 2 / overlay 0; interaction: target 2 / overlay 1; return: target 3 / overlay 1. Only routing is asserted; target activation event counts are not interpreted as game transaction counts.

The power test sends synthetic Windows power messages; it does **not** suspend the user's computer. The resulting snapshot is `.review/native-suspend-snapshot.json`. Actual sleep/hibernate duration, Godot scenery rendering under the layered style, interactive toolbar behavior, DPI changes, monitor removal, and long-duration performance still require the application acceptance tests. No synthetic event test is reported as an actual system sleep test.

The collapsed rendering test samples `toolbar.get_texture().get_image()` before and after changing its label. `.review/collapsed-toolbar-before.png` contains red `BEFORE 111`; `.review/collapsed-toolbar-after.png` contains green `AFTER 99999`. Both sampled images were visually inspected. This checks the actual rendered pixels, rather than interpreting HWND visibility as proof of rendering.
