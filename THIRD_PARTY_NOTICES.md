# 素材与技术来源

## 动画素材

`payload/assets/startup.mp4`、`poster.jpg`，以及文档中的预览和画质对比，含《鸣潮》守岸人角色与游戏画面。角色和原画相关权利归库洛游戏及相应权利人。素材来自项目发起者提供的参考录屏；本仓库不声称拥有角色、原画或原始视频的版权，也不将代码 MIT 许可扩展到这些素材。

制作保留了原录屏动画的碎线聚合、闭眼线稿、显色与后续人物动作；原始有效画面约 690×544。时间映射为原录屏 16.10–18.20 秒压至输出 0–1.4 秒，18.20–24.65 秒压至输出 1.4–5 秒。

## AI 画质处理

使用 [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) 的 [AnimeVideo-v3 x3 模型](https://github.com/xinntao/Real-ESRGAN/blob/master/docs/anime_video_model.md)，通过 [Real-ESRGAN-ncnn-vulkan](https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan) 离线逐帧处理 300 帧，再合成 2560×1440 / 60fps / 5 秒 MP4。这是 AI 重建输出，并非原生 1440p 录制。

本插件不分发超分工具、模型、GPU 驱动或 FFmpeg；安装和启动不运行 AI 推理。相关项目许可按其各自仓库为准。

## 安装和窗口控制

启动方案曾参考 [Windows Codex 启动动画项目](https://github.com/yanami-sec/codex-startup-animation-windows) 的思路。此仓库中的窗口握手、前台确认、首帧暂停、页面转场及安装管理脚本为本项目实现；未打包该项目的程序文件。

蝴蝶图标为本项目自绘几何图形，不含 OpenAI 或游戏商标图标。
