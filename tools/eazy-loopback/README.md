# EazyLoopback

EazyLoopback 是一个 Windows 音频输入监听工具。选择录音设备和播放设备，即可实时监听输入声音，并将监听增益调节到 0–2000%。界面使用 WPF，不处理视频。

## 功能

- 选择系统默认或指定的录音、播放设备
- 实时监听；调节后试听所选播放设备
- 可展开的输入和输出左右声道电平、削波提示
- Windows 声音设置、音量合成器、设备管理器等快捷入口

## 运行

在 Windows 10/11 上双击 `EazyLoopback.cmd`。也可使用 Windows PowerShell 5.1 运行：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\EazyLoopback.ps1
```

不需要安装额外音频库。设备属性快捷入口可直接打开系统默认输入或输出设备的属性窗口。超过 100% 的增益可能使音频削波，界面会显示提示。

## 许可证

Copyright © 2026 GoldesqueMoON。EazyLoopback 按 [Apache-2.0](LICENSE) 发布。


分发时保留 LICENSE、NOTICE 和源文件版权声明。本仓库不包含额外音频库；监听由 Windows 内置音频接口完成。
