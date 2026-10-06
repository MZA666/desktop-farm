# Git 维护说明

Git 在本地记录每次代码修改；GitHub、GitLab 或 Gitee 仓库保存远端副本。浏览器登录用于管理网站，首次从命令行推送可能仍需通过 Git Credential Manager 登录。

本项目已接入 [MZA666/desktop-farm](https://github.com/MZA666/desktop-farm)，远端名为 `origin`、分支为 `main`。下面的“首次接入”用于全新项目；当前项目日常修改只需检查、提交、推送，不需要重复添加远端。

## 首次接入远端

1. 在你使用的代码平台创建空仓库，名称可用 `desktop-farm`，建议首期设为私有仓库。
2. 不预先添加 README、`.gitignore` 或许可证文件；本地已有相应文件，空仓库可以直接接收首次提交。
3. 复制该仓库的 HTTPS 克隆地址，在 `D:\game` 中执行下列命令。将占位地址替换为你创建的实际地址。

```powershell
git remote add origin <你的仓库HTTPS地址>
git push -u origin main
```

命令中的 `<你的仓库HTTPS地址>` 必须先替换，不能直接复制执行。首次登录请使用代码平台或 Git Credential Manager 的认证窗口。浏览器中的个人主页地址不是仓库克隆地址。

## 日常修改

在项目目录先检查改动，确认需要提交的文件后建立记录，再推送到远端：

```powershell
git status
git diff
git add <本次需要提交的文件路径>
git commit -m "修复或功能的具体说明"
git push
```

首次提交前还没有远端时，`git commit` 可以正常建立本地记录；配置远端后再执行 `git push`。`git diff` 查看尚未暂存的改动，`git diff --staged` 查看即将提交的内容。

较大的功能可使用独立分支，完成后合入主分支：

```powershell
git switch -c codex/new-feature
```

发布可用带说明的标签，例如 `git tag -a v0.8.4 -m "v0.8.4 field and area net upgrades"`，然后 `git push origin v0.8.4`。标签对应已验收源码，试玩包由本机 `dist/` 构建，不随源码提交。0.8.4分支为 `codex/v0.8.4-field-and-net-upgrades`，保留此前版本记录；本轮增加4块边缘耕地、就近派工和渔网面积升级。版本标签用于定位已验收源码；GitHub主分支未自动合并这些功能分支。

## 换电脑开发

先安装 Git 和 Python 3，然后克隆仓库，在克隆目录中执行：

```powershell
git clone <你的仓库HTTPS地址>
cd desktop-farm
./scripts/setup_toolchain.ps1
./native/build.ps1
python ./tests/validate_config.py
./scripts/test.ps1
./scripts/run.ps1
```

首次准备需要网络。工具版本固定在准备脚本中，本机绝对路径写入忽略的 `.tools/toolchain.json`。数值源快照在 `data/source/workbook-v0.5.json` 中，并通过 Git 属性保留字节；不要由编辑器单独转换其换行或编码，否则 SHA256 来源核验会失败。

如需生成 Windows 试玩包，先执行 `python ./scripts/download_windows_templates.py` 下载对应导出模板，再执行 `./scripts/build.ps1`。
