# 守岸人 · Codex 启动动画插件

Windows Codex 主窗口里的 5 秒守岸人启动动画：碎线聚合、线稿显色、人物动态，再收束到真实聊天输入区。视频已做逐帧 AI 超分，输出 2560×1440 / 60fps；启动时直接播放，无需显卡模型或额外 API。

![5 秒启动与转场预览](docs/preview.gif)

[下载 v1.1.0 完整安装包](https://github.com/Koi-Tang/Jack_Pagac/archive/refs/tags/v1.1.0.zip) · [高清动画](plugins/codex-shorekeeper-startup/payload/assets/startup.mp4) · [画质对比](docs/quality-comparison.png)

## 直接安装

1. 下载上面的 ZIP，右键“全部解压”。不要在 ZIP 里直接运行。
2. 双击根目录 `install.cmd`，等待显示安装成功。不需要管理员权限。
3. 双击桌面的 **守岸人 Codex**。完全退出后再打开时，会从第 0 帧播放 5 秒开场。若 Codex 已打开、最小化或隐藏在托盘，则直接恢复聊天窗口。动画播到一半再次点击会继续当前播放。

首次默认只创建一个“守岸人 Codex”入口，保留现有 ChatGPT / Codex 图标；升级会延续此前已选择的入口模式。动画在真实 Codex 窗口内播放，等待官方客户端初始化的时间不计入 5 秒；窗口真正显示后才从第 0 帧播放。Esc、空格、回车或右下角按钮可跳过。

文件会复制到 `%LOCALAPPDATA%\CodexShorekeeper`。安装完成后可删除下载和解压目录；插件缓存更新也不会让桌面入口失效。

## 作为 Codex 插件安装

这是带本地 PowerShell 安装技能的桌面插件，同时提供仓库 marketplace。公开 GitHub 分发不等于已上架官方插件商店。

```powershell
codex plugin marketplace add Koi-Tang/Jack_Pagac
```

重新打开桌面客户端，在插件目录选择 **守岸人 Codex 启动动画** 来源，安装 **守岸人启动动画**，然后发送：

```text
使用 $shorekeeper-startup 安装守岸人启动动画。
```

也可以让该技能“预览动画”“检查安装”“升级到当前插件版本”或“卸载并恢复入口”。安装插件仅提供技能；用户调用安装后，才会部署文件和修改所选桌面快捷方式。

若客户端尚不支持 `codex plugin marketplace add`，可使用上面的直接安装方式；插件格式依据 [OpenAI 官方打包文档](https://developers.openai.com/plugins/build/plugins)。

## 预览、诊断、升级和卸载

| 操作 | 根目录入口 | 结果 |
| --- | --- | --- |
| 预览 | `preview.cmd` | 浏览器展示模拟聊天界面的 5 秒转场，不启动真实 Codex |
| 诊断 | `diagnose.cmd` | 检查官方应用、文件哈希及已安装状态，不启动应用 |
| 安装 / 升级 | `install.cmd` | 校验随包文件，再部署到固定安装目录；保留原快捷方式备份 |
| 卸载 | `uninstall.cmd` | 恢复原快捷方式，删除本项目拥有且未被修改的文件 |

如果下载目录已删除，可直接运行 `%LOCALAPPDATA%\CodexShorekeeper\uninstall.cmd` 完整卸载，或运行同目录的 `restore.cmd` 仅恢复桌面入口。卸载不会关闭当前聊天，官方程序本体未被修改。

希望原来的 ChatGPT / Codex 图标也播放动画，可显式执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\plugins\codex-shorekeeper-startup\scripts\manage.ps1 -Action Install -ReplaceOfficial
```

该选项只替换能确认属于官方 Codex 的桌面入口，修改前备份并校验；遇到其他程序、旧版自定义入口或用户改过的快捷方式会停止，保留现状。首次未加 `ReplaceOfficial` 时不会替换原图标。

已经使用过替换模式、现在想只保留独立入口时，先运行安装目录内的 `restore.cmd` 恢复入口，再按默认方式安装。

## 兼容性与工作方式

- Windows 10 / 11，Microsoft Store 版 Codex，Windows PowerShell 5.1、.NET Framework 4.x。实测官方包版本 `26.1027.6604.0`（x64）。当前原生辅助程序为 AnyCPU；ARM64 未实测。
- 自动发现并验证官方包和发布者，使用 Codex 自带 Node.js。不下载第三方运行时，不指定或迁移用户资料目录。
- 通过 `127.0.0.1:19341` 本地调试接口，核对监听进程、目标页面和原生窗口后载入临时动画层。接口随官方进程存在；不要将端口转发到网络。
- 不读取账号和聊天文件，不改 `app.asar`。官方界面、应用包结构或调试协议更新后可能需要适配。
- 从原版入口启动的实例也能通过 Windows 窗口恢复进入当前聊天。已有实例走窗口恢复流程，只有冷启动才加载视频和动画层。日志中的 `resumed-existing` 表示已恢复已有实例。
- 错误诊断在安装目录 `launcher/runtime/`，最近一次为 `launcher/last-launch.log`。公开反馈前请去除日志里的本机路径。

## 开发与验证

仓库内含所有 PowerShell、JavaScript 和 C# 源码，以及预编译辅助程序。安装按 `payload-manifest.json` 校验路径、大小和 SHA-256；构建不需要联网。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\plugins\codex-shorekeeper-startup\scripts\build.ps1
```

隔离生命周期测试见 [installation-lifecycle.ps1](plugins/codex-shorekeeper-startup/tests/installation-lifecycle.ps1)，只使用临时桌面目录和临时安装目录。v1.1.0 新增已运行实例恢复，沿用现有开场与转场。

## 许可与来源

程序代码采用 [MIT License](LICENSE)。守岸人角色、游戏画面和视频不属于代码许可，相关权利归各自权利人；处理与来源见 [素材说明](THIRD_PARTY_NOTICES.md)。本项目是个人定制工具，与 OpenAI 或库洛游戏无隶属或授权关系。
