# ChatGPT 更新工具

单个 PowerShell 脚本，支持原生 WPF 界面、命令行菜单和直接执行功能。适用于 Windows 10/11；不需要安装第三方界面库。

## 运行

在本工具目录打开 PowerShell，运行：

    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File ".\ChatGPT-Updater.ps1"

不带功能参数时打开 WPF 图形界面。在上面的命令后追加 -Tui 打开命令行菜单，追加 -Mode Check 等参数则直接执行对应功能。也可以在已允许脚本执行的 PowerShell 中运行：

    .\ChatGPT-Updater.ps1                           # WPF 界面
    .\ChatGPT-Updater.ps1 -Tui                      # 命令行菜单
    .\ChatGPT-Updater.ps1 -Mode Check               # 检查并显示版本
    .\ChatGPT-Updater.ps1 Update                    # 直接下载、验证和安装
    .\ChatGPT-Updater.ps1 -Mode InstallMonitor -Hour 10
    .\ChatGPT-Updater.ps1 -Mode RemoveMonitor
    .\ChatGPT-Updater.ps1 -Mode Repair
    .\ChatGPT-Updater.ps1 -Mode Check -Silent       # 静默检查

-Mode 也可写成 -Action；功能名支持位置参数和大小写不敏感。原有 -Mode Menu 仍可使用。PowerShell 7 运行时，脚本会转交系统 Windows PowerShell 5.1，避免 Appx 模块兼容问题。

## 操作行为

- 默认显示进度、结果和错误。-Silent 抑制控制台输出、进度和桌面通知，仍写日志；静默修复不会弹 UAC，权限不足返回失败。
- GUI 和 TUI 中的安装、服务修复有确认提示；直接指定功能参数会执行该功能。
- 每日检查默认仅提醒。只有明确指定 -Mode InstallMonitor -AutoInstall 才会配置自动安装。
- 安装可能关闭正在运行的 ChatGPT。服务修复会先备份 DoSvc 注册表，再修改其 DLL 配置并启动 DoSvc、BITS；提权最多请求一次。
- 安装和修复互斥，重复任务会报错。GUI 在后台运行功能，执行期间仍可响应；可随时关闭窗口：检查会立即终止，下载会取消并保留可续传分片；已进入 Windows 安装或服务修复提交阶段的任务会在后台完成，避免中断系统操作。
- 无功能参数时不能单独指定 -Silent；GUI、TUI 不接受静默模式。

## 高分辨率界面

使用标准 WPF 窗口、按钮、复选框和下拉框。创建窗口前启用 Per-Monitor V2 DPI 感知及 WPF DPI 缩放，配合布局取整和文本渲染，以当前显示器 DPI 渲染文字和控件。

## 路径和来源

- 下载：%LOCALAPPDATA%\ChatGPTUpdater\downloads
- 日志：%LOCALAPPDATA%\ChatGPTUpdater\logs\monitor.log
- 修复备份：%ProgramData%\ChatGPTUpdater\repair-backups

包名为 OpenAI.Codex，更新包来自第三方 GitHub 镜像 NNNaughtyDog/codex-desktop-mirror-plus，镜像可能晚于官方。安装前必须通过 SHA-256、Windows 数字签名、发布者、包身份、版本和架构校验。

退出码：0 成功，1 失败，2 取消，10 检查成功且发现可用更新（仅 Check）。更多参数可用 Get-Help .\ChatGPT-Updater.ps1 -Detailed 查看。

## 中英文切换

GUI 右上角选择“简体中文”或“English”，界面、进度提示和应用消息会即时切换，并保存到 %LOCALAPPDATA%\ChatGPTUpdater\settings.json。TUI 选项 6 可切换语言。

命令行使用 -Language zh-CN 或 -Language en-US，别名为 -Lang。默认 Auto 优先读取保存的偏好，再跟随 Windows 界面语言。Windows 底层错误和系统对话框按钮使用系统自身的语言。

    .\ChatGPT-Updater.ps1 -Language en-US
    .\ChatGPT-Updater.ps1 -Tui -Language zh-CN
    .\ChatGPT-Updater.ps1 -Mode Check -Language en-US -Silent

## 并行下载

- 默认最多 8 个并行 HTTP 连接，可在 GUI 修改，或用 -Connections 1..16（别名 -Threads）。
- 内置 .NET HttpClient 分段下载器包含在脚本中，无需额外安装工具。支持断点续传、退避重试、范围响应验证和 SHA-256 校验；服务器不支持 Range 或文件过小时使用单连接。
- 分片以预期哈希、大小、连接数绑定，避免不同版本的分片混用。关闭后重开，使用相同连接数可继续；更改连接数时会重新划分分片。
- 可选集成 aria2c：检测 PATH 或 %LOCALAPPDATA%\ChatGPTUpdater\tools\aria2c.exe。Auto 优先使用已安装的 aria2，否则使用内置后端。也可指定 -Downloader BuiltIn 或 -Downloader Aria2。脚本不会自动安装第三方工具。
- aria2 使用多连接、续传、证书检查和 SHA-256 参数；之后仍须通过相同的官方数字签名与 MSIX 身份校验。详见 [aria2 官方文档](https://aria2.github.io/manual/en/html/aria2c.html)。

    .\ChatGPT-Updater.ps1 -Mode Update -Connections 8 -Downloader BuiltIn
    .\ChatGPT-Updater.ps1 -Mode Update -Connections 8 -Downloader Aria2

## 检查和安装分别依赖什么

| 功能 | 依赖 |
| --- | --- |
| GUI | Windows PowerShell 5.1、.NET Framework 的 WPF；PowerShell 7 会自动转交系统 5.1 |
| 本机版本 | Windows Appx 模块的 Get-AppxPackage，查找 OpenAI.Codex |
| 可下载版本 | HTTPS 访问 GitHub 的 NNNaughtyDog/codex-desktop-mirror-plus 发布页和资源列表 |
| 下载 | 内置 .NET HttpClient，或可选的 aria2c；不通过 BITS 下载 |
| 校验 | .NET SHA-256、Windows Authenticode 证书信任、MSIX Manifest |
| 安装 | Windows PowerShell Add-AppxPackage 和 Windows AppX/MSIX 部署服务 |
| 每日提醒 | Windows 任务计划程序及 ScheduledTasks 模块 |
| 修复服务 | 管理员权限、reg.exe、DoSvc 和 BITS；这不是检查版本的前置步骤 |

检查的是第三方镜像的可下载版本，并未直接查询 OpenAI 官方自动更新接口。镜像未同步时，显示的版本可能落后于官方。脚本也不负责自动补装某个 MSIX 包声明的缺失运行库。


## 许可证

Copyright 2026 GoldesqueMoON。工具主体按 [Apache-2.0](LICENSE) 开源；分发时保留 LICENSE、NOTICE 和源文件版权声明。aria2 和下载的 ChatGPT 安装包不随本仓库分发，各自保留其原有许可。
