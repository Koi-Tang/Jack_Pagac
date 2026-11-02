---
name: shorekeeper-startup
description: 安装、升级、预览、诊断或卸载 Windows Codex 守岸人 5 秒高清启动动画。用于本插件的桌面动画与入口管理；不用于账号、聊天数据或其他插件配置。
---

# 守岸人启动动画

本技能为 Windows Store 版 Codex 部署已制作好的 5 秒动画。插件根目录是本技能目录的 `../..`，管理脚本位于插件根目录 `scripts/manage.ps1`。始终由当前已安装插件的本地路径解析脚本，不假设仓库或用户名。

按用户请求选择 `-Action Install|Diagnose|Preview|Uninstall`，通过 Windows PowerShell 5.1 执行脚本。安装请求已授权部署和创建默认的“守岸人 Codex”入口，无需再询问同一安装动作。

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "<插件实际路径>\scripts\manage.ps1" -Action Diagnose
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "<插件实际路径>\scripts\manage.ps1" -Action Install
```

安装或升级时先运行只读 Diagnose，检查官方应用与包状态，再运行 Install。安装器校验 `payload-manifest.json` 并复制到 `%LOCALAPPDATA%\CodexShorekeeper`，保留已有备份。安装完成后再次 Diagnose，报告实际安装目录及桌面入口。

用户明确要求替换原 ChatGPT / Codex 图标时，Install 加 `-ReplaceOfficial`；默认仅独立创建一个守岸人入口。若检测到其他自定义入口或用户修改过的快捷方式，解释脚本的实际冲突，不覆盖或删除它。

升级会延续已记录的入口模式。若用户明确要求从过去的“替换原图标”改为“仅独立入口”，先执行安装目录的 `launcher/restore-desktop.ps1` 恢复已管理入口，再默认 Install；仅省略 `-ReplaceOfficial` 不会撤销过去的替换选择。保留用户当前会话，恢复操作不关闭应用。

Preview 只展示浏览器模拟界面；不要声称这验证了真实客户端冷启动。Diagnose 不启动应用。不要为验证主动关闭当前 Codex、结束进程或重开用户聊天。

若当前实例缺少本地动画接口，告知用户保存工作后从托盘完全退出一次，再点“守岸人 Codex”；让用户自行完成。安装器不改官方安装包或用户资料目录。5 秒是可见动画时长，客户端初始化另计。

卸载请求执行 Uninstall，恢复有校验备份的原快捷方式，并仅移除本项目拥有且未被修改的文件。报告脚本保留下来的用户修改或日志，不承诺删除未删除的内容。

`-Destination`、`-DesktopPath` 是自定义位置参数，通常保持默认。`-SkipAppCheck` 仅用于用户明确选择的离线预装或隔离测试；不能用于把不兼容安装报告成正常。

脚本失败时保留具体错误，先诊断，不循环重装或改写未知文件。诊断日志可能含本机路径，未经用户要求不要上传 GitHub 或其他服务。
