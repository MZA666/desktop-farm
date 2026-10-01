# 桌面农场

Windows 11 x64 本地像素风放置游戏，当前版本 0.8.0（阶段A：独立种植与自然农田）。Godot 4.7.2、类型化 GDScript、C/Win32 GDExtension。作物、动物、产物和农夫使用原创生成的像素图集，地形与建筑由程序绘制，中文使用系统字体。

## 试玩

双击 `dist/DesktopFarm-v0.8.0/DesktopFarm.exe`，保持同目录的 `.pck` 和 DLL 文件。无需安装 Godot、Python 或编译器。「种子商店」按数量购买入库并选择默认自动订购；「种子库」选择品种后在农田点击、框选或按 Shift 多选地块，提交种植安排。当前作物完成本轮后换种，取消安排会释放预留种子。整个可用库为空才自动订购，其他库存按固定品种顺序继续播种。

每块地独立管理，初始24、最多96块；建设中每次开垦一块。设置可调农夫速度16～48像素/秒，默认32；按实际距离行走，到达后才开始2秒动作。所有游戏窗口遵循普通 Windows 前后顺序，点击其他应用后该应用优先显示。

托盘菜单和 `Ctrl+Alt+F` 可显示/隐藏游戏，同显示器前台全屏应用会暂时隐藏全部游戏窗口；后台生产继续。快捷键占用时显示明确提示，可继续使用托盘。仅收起场景时工具栏仍可经营。

窄屏下商店快捷按钮会收进经营首页，托盘也能直接打开两个商店。

玩法说明见 [试玩说明](docs/play-guide.txt)；当前规则见 [阶段A开发规格](docs/development-spec-v0.8.md)；实际验收与未测项目见 [验收记录](docs/validation-v0.8.md)。后续动物自由移动、自然牧草和互动加成安排在阶段B（0.8.1），渔网与鱼容量升级安排在阶段C（0.8.2），见 [完整开发方案](docs/development-proposal-v0.8.md)。美术方向与素材来源见 `docs/art-direction-v0.7.md`，完整生成提示词见 `assets/pixel/generation-prompts.md`。

便携试玩压缩包为 `dist/DesktopFarm-v0.8.0-win64.zip`，解压后启动程序。包中附开发文档和验收记录。启动前先退出旧版游戏；首次载入旧存档会验证并备份原文件，再升级为v2，保留金币、库存及生产进度。

## 源码运行与构建

首次准备：

```powershell
./scripts/setup_toolchain.ps1
./native/build.ps1
./scripts/run.ps1
```

工具只下载到 `.tools/`，不安装到系统。首次准备需要网络；准备脚本固定使用已验证的 Godot 4.7.2 与 Zig 0.16.0，本机工具路径和校验值写入 `.tools/toolchain.json`。该文件不进入 Git，新电脑重新运行准备脚本。

```powershell
./scripts/test.ps1
./scripts/run.ps1 -Editor
./scripts/build.ps1
```

只更新随包说明、保留已经测量过的EXE/PCK/DLL时，可执行 `./scripts/build.ps1 -PackageOnly`；该参数不会编译源码变化。

Windows 导出需要 `.tools/export-templates/` 中与引擎版本一致的官方模板。安装 Python 3 后，在项目根目录执行一次：

```powershell
python ./scripts/download_windows_templates.py
```

该脚本从官方模板压缩包通过 HTTP Range 只提取 Windows x64 文件，逐文件校验 ZIP CRC 并保存下载收据。完整压缩包没有下载，收据中的整个包 SHA256 不作为已验证结果。发布打包使用真正的导出模板。

配置核验：用 Python 执行 `tests/validate_config.py`。原始数值导出脚本 `scripts/export_config.py` 读取已纳入 Git 的 `data/source/workbook-v0.5.json`，玩法运行不依赖原 Excel 或 Word。逻辑测试覆盖全部内容 ID 及满规模存档恢复；图形和原生验证的实际结果单列。

## 版本维护

源码、设计文档、数值来源和测试纳入 Git；工具、缓存、截图及 `dist/` 试玩包由本机构建生成。提交与远端同步步骤见 [Git 维护说明](docs/git-workflow.md)。

## 存档

正式试玩保存于 Windows 用户目录的 Godot `app_userdata/桌面农场/desktop-farm-save.json`。设置中可以打开实际目录。30秒自动保存，经营操作立即保存；写入失败会撤回操作。退出与休眠暂停，没有离线收益。损坏主档尝试上一完整 `.bak`；两份均坏时暂停并保留文件。迁移备份名为 `desktop-farm-save.json.version-v1-*.json`，后续保存不会覆盖它；有效旧档升级写入失败会停止启动，避免回退进度。旧版无法读v2，回退需在全部游戏退出后使用原版备份。

原始需求、数值来源及已确认变化记录在 `docs/requirements-review-v0.5.md`。源码目录 `.review/`、`.tools/`、测试、截图及原始文件不随试玩包发布。
