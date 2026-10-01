# Windows desktop bridge

This module uses the official Godot GDExtension C interface and Windows APIs; it does not require `godot-cpp`, Visual Studio installation, or .NET. The build uses the portable Zig compiler pinned in `.tools/toolchain.json`. `desktop_native.gdextension` loads `bin/desktop_native.dll` on Windows x64; the minimum Godot version is 4.4.

Build from the project directory:

```powershell
./native/build.ps1
./native/build_tests.ps1
```

`DesktopHost.start(scene_window, toolbar_window, settings)` converts the scenery's Godot window ID to a native HWND and attaches `DesktopNative`. The HWND receives `WS_EX_LAYERED`, `WS_EX_NOACTIVATE`, and `WS_EX_TOOLWINDOW`; observation mode adds `WS_EX_TRANSPARENT`, and interaction removes it. The separate toolbar window stays clickable. The bridge does not call `mouse_passthrough_polygon`, replace the Godot window procedure, or rely on Godot's mouse passthrough flag for scenery input.

`get_work_area()` returns the current monitor's `rcWork` as a `Rect2i`, excluding the taskbar. `get_dpi_scale()` returns `GetDpiForWindow(hwnd) / 96`. Layout uses physical window coordinates and informs the UI when the work area or scale changes. `try_single_instance()` retains a per-session named mutex until `release()` or process exit.

Collapsing uses native `set_visible(false)` / `ShowWindow(SW_HIDE)` because Godot does not permit setting its main `Window.visible` to false. The host disables the main rendering viewport while keeping the scene tree and clock active. Expansion restores the viewport and uses `SW_SHOWNA`. The toolbar is a top-level window, detached from a native owner if necessary, and `show_window(toolbar_hwnd)` ensures its native visibility even during an initially collapsed startup. Showing an already-visible window is a no-op, so settings refreshes do not change its Z order. Its rendering viewport is also detached from the main viewport with `viewport_set_parent_viewport(toolbar_rid, RID())`; otherwise disabling the main viewport can freeze a still-visible toolbar. Other independent windows, including purchase panels, require the same rendering independence. `is_visible()` and `window_is_visible(hwnd)` report actual `IsWindowVisible` state for acceptance checks.

## Window priority correction, 2026-10-01

The scenery, toolbar, and purchase panels follow normal Windows Z order. `project.godot` starts without `always_on_top`; `DesktopHost` ignores legacy `topmost=true` settings and its legacy `set_topmost()` API always keeps ordinary priority. Native attachment and independent-window setup defensively demote existing `WS_EX_TOPMOST` windows. Repeated demotion is skipped when the flag is already absent, because calling `SetWindowPos(HWND_NOTOPMOST)` unnecessarily can move an ordinary window within its normal Z band. The monitor/layout loop does not activate or raise windows, and unchanged geometry avoids unnecessary native setter calls.

The new `test_window_priority.gd` launched three real Godot HWNDs plus a controlled foreground app in another process. A real mouse click activated that app; it remained above all three game windows while the host repeatedly refreshed old `topmost=true` settings, switched input modes, refreshed visibility, moved the scenery/toolbar by eight physical pixels, and recomputed layout. Result: `HOST_WINDOW_PRIORITY_PASS`. The standalone `priority_probe.exe desktop_native.dll` also verifies that initially topmost controlled HWNDs are demoted and repeated native style/show calls leave the foreground app above them.

The mouse-routing probe explicitly activates its controlled overlay before the interaction phase, with permission from its controlled foreground child. This is test setup after observation has naturally brought the other process to the front; the product never requests another app's foreground permission. Actual routing still passes observation: target 2 / overlay 0, interaction: target 2 / overlay 1, return: target 3 / overlay 1. Collapse visibility and the awake clock (907 ms while hidden), actual collapsed toolbar pixel updates, and synthetic suspend/resume callbacks were rerun successfully after the priority correction. No user's unrelated application or actual system sleep was used in these tests.

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
