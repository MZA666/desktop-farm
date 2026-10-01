# 桌面农场

Windows 11 x64 本地像素风放置游戏，按照 `docs/development-spec-v0.6.md` 开发。Godot 4.7.2、类型化 GDScript、C/Win32 GDExtension。占位像素精灵由程序原创绘制，中文使用系统字体。

## 试玩

双击 `dist/DesktopFarm-v0.6.1/DesktopFarm.exe`，保持同目录的 `.pck` 和 DLL 文件。无需安装 Godot、Python 或编译器。控制栏直接提供「种子商店」「动物商店」，「经营」可进入扩建、农夫、图鉴和设置。所有游戏窗口遵循普通Windows前后顺序，点击其他应用后该应用优先显示。

玩法说明见 `docs/play-guide.txt`；开发规格见 `docs/development-spec-v0.6.md`；实际验收与未测项目见 `docs/validation-report.md`。

便携试玩压缩包为 `dist/DesktopFarm-v0.6.1-win64.zip`，解压后启动程序。包中附开发文档和验收记录，沿用已有存档。

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

Windows 导出需要 `.tools/export-templates/` 中与引擎版本一致的官方模板。安装 Python 3 后，在项目根目录执行一次：

```powershell
python ./scripts/download_windows_templates.py
```

该脚本从官方模板压缩包通过 HTTP Range 只提取 Windows x64 文件，逐文件校验 ZIP CRC 并保存下载收据。完整压缩包没有下载，收据中的整个包 SHA256 不作为已验证结果。发布打包使用真正的导出模板。

配置核验：用 Python 执行 `tests/validate_config.py`。原始数值导出脚本 `scripts/export_config.py` 读取已纳入 Git 的 `data/source/workbook-v0.5.json`，玩法运行不依赖原 Excel 或 Word。逻辑测试覆盖全部内容 ID 及满规模存档恢复；图形和原生验证的实际结果单列。

## 版本维护

源码、设计文档、数值来源和测试纳入 Git；工具、缓存、截图及 `dist/` 试玩包由本机构建生成。提交与远端同步步骤见 [Git 维护说明](docs/git-workflow.md)。

## 存档

正式试玩保存于 Windows 用户目录的 Godot `app_userdata/桌面农场/desktop-farm-save.json`。设置中可以打开实际目录。30秒自动保存，经营操作立即保存；写入失败会撤回操作。退出与休眠暂停，没有离线收益。损坏主档尝试上一完整 `.bak`；两份均坏时暂停并保留文件。

原始需求、数值来源及已确认变化记录在 `docs/requirements-review-v0.5.md`。源码目录 `.review/`、`.tools/`、测试、截图及原始文件不随试玩包发布。
