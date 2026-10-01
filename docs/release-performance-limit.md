# 导出程序的外部脚本性能测试限制

记录日期：2026-10-01。程序为 `D:\game\dist\DesktopFarm-v0.6\DesktopFarm.exe`，同目录独立 `DesktopFarm.pck`。此前外部 `--script` 路径没有取得有效的 release 样本；随后通过正常主场景入口的夹具参数完成了五阶段实测，结果见 [Release 性能报告](release-performance-v0.6.md)。本页保留外部脚本不可用的证据，不能将那次失败尝试或源码样本当作导出程序性能。

实际尝试：

```powershell
& 'D:\game\tests\benchmark_runtime.ps1' -EnginePath 'D:\game\dist\DesktopFarm-v0.6\DesktopFarm.exe' -Exported
```

该模式不传 `--path`，使用外部绝对 `--script D:\game\tests\benchmark_runtime.gd`，输出目标为绝对目录 `.review\release-benchmark`，并传入 `--benchmark-fixture` 以隔离正式存档。渲染器打印了正常引擎/OpenGL头，但 20 秒内没有生成 helper 的 `benchmark-stage.json`，采样器停止自己启动的测试进程并退出 1；没有生成任何有效 CPU/内存阶段结果。该次尝试的包随后因独立发现的子窗口刷新修复被替换，也不用于最新版收起验收。

进一步执行 release EXE 的 `--help`，命令成功退出 0。帮助中没有 `-s, --script` 或 `--main-loop` 选项，只在 headless 通用说明里提到脚本。与实际 helper 未执行的现象一致。

Godot 4.7.2 官方启动源码中，外部脚本及主循环覆盖受 `OVERRIDE_PATH_ENABLED` 控制；未启用时会清空 `script`、`game_path` 与 `main_loop_type`，转为加载项目正常主场景。项目禁止配置覆盖时也会清空这些字段。因此当前官方 release 模板不能用这条外部 helper 路径完成控制场景的测试。[Godot 4.7.2 启动源码](https://raw.githubusercontent.com/godotengine/godot/4.7.2-stable/main/main.cpp)

`tests/benchmark_runtime.ps1 -Exported` 现已增加无 GUI 的 `--help` 预检：模板没有真正的 `--script` 选项就明确退出，避免再次误启动普通游戏后等待 helper。没有为了测试把 helper 塞进发布包，也没有更换成非官方自编译模板。

新的 `tests/benchmark_release.ps1` 通过正常应用入口传入仅测试夹具有效的场景、省电、收起及限时参数，无 `--path`、无 `--script`，对实际 EXE 的 PID 采集 CPU/内存。五阶段均完成并退出 0；只有收起 CPU 低于 2%，全部工作集峰值超过 200,000,000 字节（200 MB），详见 `release-performance-v0.6.md`。历史源码报告 `performance-sample-v0.6.md` 保留，其中旧收起点因子窗口冻结已作废；每模式 30 分钟的正式验收仍未完成。
