# Copyright 2026 GoldesqueMoON
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
单文件 ChatGPT 更新工具：WPF 界面、命令行菜单和直接执行。
.DESCRIPTION
无参数打开 WPF 界面，-Tui 打开菜单。指定 -Mode 或位置参数直接执行功能。
默认显示操作过程；-Silent 抑制控制台输出、进度、通知和 UAC，仍写日志。
退出码：0 成功；1 失败；2 取消；10 检查成功且有可用更新（仅 Check）。
.PARAMETER Mode
Check / Status 检查版本；Update 安装更新；InstallMonitor / RemoveMonitor 管理每日检查；
Monitor 执行一次定时检查；Repair 修复服务。Gui、Menu 显式选择图形界面或菜单。
.PARAMETER Tui
打开命令行菜单。
.PARAMETER Silent
静默执行指定功能。修复需事先以管理员身份运行。
.PARAMETER Language
Auto（保存的偏好或系统语言）、zh-CN、en-US；GUI 与 TUI 可实时切换。
.PARAMETER Connections
并行下载连接数，1 到 16，默认 8。
.PARAMETER Downloader
Auto 自动选择已安装的 aria2，否则使用内置 .NET；也可指定 BuiltIn 或 Aria2。
.PARAMETER Hour
每日检查的小时（0 至 23），默认 10。
.PARAMETER AutoInstall
仅配合 InstallMonitor 或 Monitor，明确允许定时检查自动安装。
.EXAMPLE
.\ChatGPT-Updater.ps1
.EXAMPLE
.\ChatGPT-Updater.ps1 -Tui
.EXAMPLE
.\ChatGPT-Updater.ps1 -Mode Check
.EXAMPLE
.\ChatGPT-Updater.ps1 Update -Silent
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [Alias('Action')]
    [ValidateSet('Gui','Menu','Check','Status','Update','Monitor','InstallMonitor','RemoveMonitor','Repair')]
    [string]$Mode,
    [switch]$Tui,
    [switch]$Silent,
    [switch]$AutoInstall,
    [Alias('Lang')][ValidateSet('Auto','zh-CN','en-US')][string]$Language = 'Auto',
    [Alias('Threads')][ValidateRange(1,16)][int]$Connections = 8,
    [ValidateSet('Auto','BuiltIn','Aria2')][string]$Downloader = 'Auto',
    [ValidateRange(0,23)][int]$Hour = 10,
    [Parameter(DontShow)][switch]$ElevatedOnce,
    [Parameter(DontShow)][switch]$HostRestarted,
    [Parameter(DontShow)][string]$ResultPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = if ($Silent) { 'SilentlyContinue' } else { 'Continue' }
$script:ScriptPath = $PSCommandPath
$script:WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:Repo = 'NNNaughtyDog/codex-desktop-mirror-plus'
$script:PackageName = 'OpenAI.Codex'
$script:ExpectedPublisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
$script:TaskName = 'ChatGPT Desktop Update Monitor'
$script:DataDir = Join-Path $env:LOCALAPPDATA 'ChatGPTUpdater'
$script:DownloadDir = Join-Path $DataDir 'downloads'
$script:LogFile = Join-Path $DataDir 'logs\monitor.log'
$script:LastProgress = -2

$script:Texts = @{}
$catalog = @'
{
  "Title": {
    "zh-CN": "ChatGPT 更新工具",
    "en-US": "ChatGPT Updater"
  },
  "Heading": {
    "zh-CN": "ChatGPT 更新",
    "en-US": "ChatGPT updates"
  },
  "Subtitle": {
    "zh-CN": "检查版本、安装更新与管理每日提醒",
    "en-US": "Check versions, install updates and manage reminders"
  },
  "Local": {
    "zh-CN": "当前版本",
    "en-US": "Installed version"
  },
  "Online": {
    "zh-CN": "镜像可下载版本",
    "en-US": "Available mirror version"
  },
  "Reading": {
    "zh-CN": "正在读取…",
    "en-US": "Reading…"
  },
  "NotInstalled": {
    "zh-CN": "未安装",
    "en-US": "Not installed"
  },
  "NotChecked": {
    "zh-CN": "尚未检查",
    "en-US": "Not checked"
  },
  "ReadFailed": {
    "zh-CN": "读取失败",
    "en-US": "Unable to read"
  },
  "CheckButton": {
    "zh-CN": "检查更新",
    "en-US": "Check for updates"
  },
  "UpdateButton": {
    "zh-CN": "安装更新",
    "en-US": "Install update"
  },
  "InstallButton": {
    "zh-CN": "立即安装",
    "en-US": "Install"
  },
  "MonitorCheck": {
    "zh-CN": "每日检查并提醒",
    "en-US": "Check daily and notify"
  },
  "Apply": {
    "zh-CN": "应用",
    "en-US": "Apply"
  },
  "Ready": {
    "zh-CN": "就绪",
    "en-US": "Ready"
  },
  "Busy": {
    "zh-CN": "正在执行，请稍候…",
    "en-US": "Working, please wait…"
  },
  "Footer": {
    "zh-CN": "安装前校验哈希、数字签名和包身份。",
    "en-US": "Hash, signature and package identity are verified before installation."
  },
  "RepairButton": {
    "zh-CN": "修复服务…",
    "en-US": "Repair services…"
  },
  "Connections": {
    "zh-CN": "下载连接数",
    "en-US": "Download connections"
  },
  "Available": {
    "zh-CN": "镜像有可安装的更新。",
    "en-US": "An update is available from the mirror."
  },
  "Current": {
    "zh-CN": "当前已是镜像可下载的最新版本。",
    "en-US": "You have the latest version available from the mirror."
  },
  "ConfirmUpdate": {
    "zh-CN": "安装时 ChatGPT 可能关闭，是否继续？",
    "en-US": "ChatGPT may close during installation. Continue?"
  },
  "ConfirmRepair": {
    "zh-CN": "将备份并修改 Windows DoSvc 服务配置，再启动 DoSvc 和 BITS。是否继续？",
    "en-US": "Back up and modify the Windows DoSvc configuration, then start DoSvc and BITS. Continue?"
  },
  "LaunchFailed": {
    "zh-CN": "无法启动：{0}",
    "en-US": "Unable to start: {0}"
  },
  "OperationFailed": {
    "zh-CN": "操作失败：{0}",
    "en-US": "Operation failed: {0}"
  },
  "Incomplete": {
    "zh-CN": "操作未完成（退出码 {0}）。请查看日志。",
    "en-US": "Operation did not finish (exit code {0}). See the log."
  },
  "Checking": {
    "zh-CN": "正在检查镜像可下载版本…",
    "en-US": "Checking the version available from the mirror…"
  },
  "Architecture": {
    "zh-CN": "仅支持 x64 和 ARM64 Windows。",
    "en-US": "Only x64 and ARM64 Windows are supported."
  },
  "BadRelease": {
    "zh-CN": "无法识别镜像版本：{0}",
    "en-US": "Cannot identify the mirror release: {0}"
  },
  "NoAsset": {
    "zh-CN": "该镜像版本没有 {0} 完整安装包。",
    "en-US": "The mirror release has no full {0} package."
  },
  "Checksum": {
    "zh-CN": "正在读取 SHA-256 校验值…",
    "en-US": "Reading the SHA-256 checksum…"
  },
  "NoChecksum": {
    "zh-CN": "校验文件中没有对应安装包。",
    "en-US": "No checksum was found for this package."
  },
  "Reuse": {
    "zh-CN": "复用已下载且哈希匹配的安装包。",
    "en-US": "Reusing the downloaded package with a matching hash."
  },
  "Verifying": {
    "zh-CN": "正在校验 SHA-256 和官方数字签名…",
    "en-US": "Verifying SHA-256 and the official signature…"
  },
  "HashFailed": {
    "zh-CN": "SHA-256 校验失败。",
    "en-US": "SHA-256 verification failed."
  },
  "SignatureFailed": {
    "zh-CN": "安装包签名无效或发布者不匹配：{0}",
    "en-US": "Package signature is invalid or the publisher does not match: {0}"
  },
  "ManifestMissing": {
    "zh-CN": "安装包缺少 AppxManifest.xml。",
    "en-US": "The package has no AppxManifest.xml."
  },
  "IdentityFailed": {
    "zh-CN": "安装包身份、版本或架构不匹配。",
    "en-US": "Package identity, version or architecture does not match."
  },
  "Verified": {
    "zh-CN": "哈希、官方数字签名和安装包身份全部通过校验。",
    "en-US": "Hash, official signature and package identity checks passed."
  },
  "NoUpdate": {
    "zh-CN": "无需更新，当前版本：{0}",
    "en-US": "No update needed. Installed version: {0}"
  },
  "Installing": {
    "zh-CN": "验证通过，正在安装；ChatGPT 可能关闭…",
    "en-US": "Verification passed. Installing; ChatGPT may close…"
  },
  "VersionFailed": {
    "zh-CN": "安装后版本为 {0}，预期为 {1}。",
    "en-US": "Installed version is {0}; expected {1}."
  },
  "Installed": {
    "zh-CN": "安装成功：{0}",
    "en-US": "Installation succeeded: {0}"
  },
  "MonitorSaved": {
    "zh-CN": "每日 {0}:00 检查已启用；自动安装：{1}。",
    "en-US": "Daily check enabled at {0}:00. Automatic installation: {1}."
  },
  "MonitorOff": {
    "zh-CN": "每日检查已关闭。",
    "en-US": "Daily checks disabled."
  },
  "Notification": {
    "zh-CN": "ChatGPT 有可用更新",
    "en-US": "A ChatGPT update is available"
  },
  "Reminder": {
    "zh-CN": "镜像版本 {0} 可安装。请打开更新工具。",
    "en-US": "Mirror version {0} is available. Open ChatGPT Updater to install."
  },
  "NeedAdmin": {
    "zh-CN": "修复需要管理员权限。请以管理员身份执行。",
    "en-US": "Repair requires administrator privileges. Run as administrator."
  },
  "RequestAdmin": {
    "zh-CN": "修复需要管理员权限，正在请求一次提权…",
    "en-US": "Repair requires administrator privileges. Requesting elevation once…"
  },
  "AdminFailed": {
    "zh-CN": "管理员修复失败，退出码：{0}。请查看日志。",
    "en-US": "Elevated repair failed (exit code {0}). See the log."
  },
  "AdminDone": {
    "zh-CN": "管理员修复已完成。",
    "en-US": "Elevated repair completed."
  },
  "DllMissing": {
    "zh-CN": "系统文件缺失：{0}",
    "en-US": "System file missing: {0}"
  },
  "BackupFailed": {
    "zh-CN": "DoSvc 注册表备份失败，未修改配置。",
    "en-US": "DoSvc registry backup failed. Configuration was not changed."
  },
  "DllWriteFailed": {
    "zh-CN": "写入 ServiceDll 失败。",
    "en-US": "Failed to write ServiceDll."
  },
  "UnloadWriteFailed": {
    "zh-CN": "写入 ServiceDllUnloadOnStop 失败。",
    "en-US": "Failed to write ServiceDllUnloadOnStop."
  },
  "ServiceStopped": {
    "zh-CN": "DoSvc 未处于运行状态。",
    "en-US": "DoSvc is not running."
  },
  "Repaired": {
    "zh-CN": "服务修复完成。备份：{0}",
    "en-US": "Service repair completed. Backup: {0}"
  },
  "Locked": {
    "zh-CN": "另一个更新或修复任务正在执行，请稍后再试。",
    "en-US": "Another update or repair is running. Try again later."
  },
  "State": {
    "zh-CN": "当前版本：{0}；镜像版本：{1}；可更新：{2}；每日检查：{3}",
    "en-US": "Installed: {0}; mirror: {1}; update available: {2}; daily check: {3}"
  },
  "Scheduled": {
    "zh-CN": "定时检查：当前={0}；镜像={1}",
    "en-US": "Scheduled check: installed={0}; mirror={1}"
  },
  "Unknown": {
    "zh-CN": "未知功能：{0}",
    "en-US": "Unknown action: {0}"
  },
  "Tui1": {
    "zh-CN": "1. 检查更新",
    "en-US": "1. Check for updates"
  },
  "Tui2": {
    "zh-CN": "2. 下载并安装更新",
    "en-US": "2. Download and install"
  },
  "Tui3": {
    "zh-CN": "3. 启用每日 {0}:00 提醒",
    "en-US": "3. Enable daily reminders at {0}:00"
  },
  "Tui4": {
    "zh-CN": "4. 关闭每日提醒",
    "en-US": "4. Disable daily reminders"
  },
  "Tui5": {
    "zh-CN": "5. 修复更新服务（需要管理员权限）",
    "en-US": "5. Repair update services (administrator)"
  },
  "Tui6": {
    "zh-CN": "6. Switch to English",
    "en-US": "6. 切换为中文"
  },
  "Tui0": {
    "zh-CN": "0. 退出",
    "en-US": "0. Exit"
  },
  "Choose": {
    "zh-CN": "请选择",
    "en-US": "Choose an option"
  },
  "TuiUpdate": {
    "zh-CN": "安装时 ChatGPT 可能关闭。输入 Y 继续",
    "en-US": "ChatGPT may close during installation. Enter Y to continue"
  },
  "TuiRepair": {
    "zh-CN": "将备份并修改 DoSvc 服务配置。输入 Y 继续",
    "en-US": "Back up and modify DoSvc configuration. Enter Y to continue"
  },
  "TuiInvalid": {
    "zh-CN": "请输入 0 到 6。",
    "en-US": "Enter 0 through 6."
  },
  "Enter": {
    "zh-CN": "按回车返回",
    "en-US": "Press Enter to return"
  },
  "TuiConflict": {
    "zh-CN": "-Tui 不能与其他功能同时使用。",
    "en-US": "-Tui cannot be combined with another action."
  },
  "SilentAction": {
    "zh-CN": "-Silent 需要指定功能，例如 -Mode Check。",
    "en-US": "-Silent requires an action, for example -Mode Check."
  },
  "SilentUi": {
    "zh-CN": "图形界面和菜单不支持 -Silent，请指定具体功能。",
    "en-US": "GUI and TUI do not accept -Silent. Specify an action."
  },
  "AutoInstallAction": {
    "zh-CN": "-AutoInstall 仅用于 InstallMonitor 或 Monitor。",
    "en-US": "-AutoInstall is only supported with InstallMonitor or Monitor."
  },
  "Host": {
    "zh-CN": "需要 Windows PowerShell 5.1 的 STA 运行环境。",
    "en-US": "Windows PowerShell 5.1 with STA is required."
  },
  "Done": {
    "zh-CN": "操作完成。",
    "en-US": "Operation completed."
  },
  "SettingsSaved": {
    "zh-CN": "每日检查设置已保存。",
    "en-US": "Daily check settings saved."
  },
  "RepairDone": {
    "zh-CN": "服务修复完成。备份保存在系统 ProgramData 下的 ChatGPTUpdater 文件夹。",
    "en-US": "Repair completed. Backups are in ChatGPTUpdater under the system ProgramData folder."
  },
  "Download": {
    "zh-CN": "正在下载：{0}%（{1} / {2} MB），{3} 个连接",
    "en-US": "Downloading: {0}% ({1} / {2} MB), {3} connections"
  },
  "DownloadEngine": {
    "zh-CN": "下载后端：{0}；最多 {1} 个并行连接。",
    "en-US": "Download backend: {0}; up to {1} parallel connections."
  },
  "DownloadWaiting": {
    "zh-CN": "正在连接下载服务器…",
    "en-US": "Connecting to the download server…"
  },
  "RangeFallback": {
    "zh-CN": "当前文件或服务器不适合分段，使用单连接下载。",
    "en-US": "File or server does not allow parallel segments. Using one connection."
  },
  "PreferenceFailed": {
    "zh-CN": "保存语言设置失败：{0}",
    "en-US": "Unable to save language preference: {0}"
  },
  "AriaMissing": {
    "zh-CN": "找不到 aria2c.exe。请加入 PATH，或使用 -Downloader BuiltIn。",
    "en-US": "aria2c.exe was not found. Add it to PATH or use -Downloader BuiltIn."
  },
  "DownloadFailed": {
    "zh-CN": "下载失败：{0}",
    "en-US": "Download failed: {0}"
  },
  "Cancelled": {
    "zh-CN": "操作已取消。已下载的分片会保留。",
    "en-US": "Operation cancelled. Downloaded fragments are retained."
  },
  "AriaProgress": {
    "zh-CN": "aria2 下载进度：{0}%",
    "en-US": "aria2 download progress: {0}%"
  },
  "AriaFailed": {
    "zh-CN": "aria2 下载失败（退出码 {0}）：{1}",
    "en-US": "aria2 download failed (exit code {0}): {1}"
  }
}
'@ | ConvertFrom-Json
foreach ($p in $catalog.PSObject.Properties) { $script:Texts[$p.Name] = @{'zh-CN'=$p.Value.'zh-CN'; 'en-US'=$p.Value.'en-US'} }

function Get-Text {
    param([string]$Key,[object[]]$Values = @())
    if (-not $script:Texts.ContainsKey($Key)) { return $Key }
    $text = $script:Texts[$Key][$script:Language]
    if ($Values.Count) { return [string]::Format([Globalization.CultureInfo]::InvariantCulture,$text,$Values) }
    return $text
}
function Set-AppLanguage {
    param([string]$Value,[switch]$Persist)
    $script:Language = $Value
    if ($Persist) {
        try {
            [void][IO.Directory]::CreateDirectory($DataDir)
            $settings = Join-Path $DataDir 'settings.json'
            $temp = $settings + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            @{ Language=$Value } | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
            Move-Item -LiteralPath $temp -Destination $settings -Force
        } catch {
            try { Write-Log (Get-Text 'PreferenceFailed' @($_.Exception.Message)) 'WARN' } catch {}
        }
    }
}
function Stop-Updater {
    param([string]$Key,[object[]]$Values=@())
    $errorObject = New-Object InvalidOperationException((Get-Text $Key $Values))
    $errorObject.Data['TextKey'] = $Key
    $errorObject.Data['TextValues'] = $Values
    throw $errorObject
}
function Test-OperationCancelled {
    if ($ResultPath -and (Test-Path -LiteralPath ($ResultPath+'.cancel'))) { Stop-Updater 'Cancelled' }
}
if ($Language -eq 'Auto') {
    try { $saved = Get-Content -LiteralPath (Join-Path $DataDir 'settings.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $saved=$null }
    $Language = if ($saved.Language -in 'zh-CN','en-US') { $saved.Language } elseif ([Globalization.CultureInfo]::CurrentUICulture.Name -like 'zh*') { 'zh-CN' } else { 'en-US' }
}
Set-AppLanguage $Language

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $LogFile))
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    if (-not $Silent) { Write-Host $line }
}


function Report-OperationProgress {
    param([string]$Key,[int]$Percent=-1,[object[]]$Values=@())
    $message = Get-Text $Key $Values
    if ($ResultPath) {
        @{ Key=$Key; Values=$Values; Message=$message; Percent=$Percent } | ConvertTo-Json -Depth 4 -Compress |
            Set-Content -LiteralPath ($ResultPath+'.progress') -Encoding UTF8
    }
    if ($Percent -ne $script:LastProgress -or $Percent -lt 0) {
        Write-Log $message
        $script:LastProgress=$Percent
    }
    if (-not $Silent -and $Percent -ge 0) { Write-Progress -Activity (Get-Text 'Heading') -Status $message -PercentComplete $Percent }
}

function Get-NativeArchitecture {
    switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
        'X64' { return 'x64' }
        'Arm64' { return 'arm64' }
        default { Stop-Updater 'Architecture' }
    }
}

function Get-LatestRelease {
    Test-OperationCancelled
    Report-OperationProgress 'Checking'
    $headers = @{ 'User-Agent'='ChatGPT-Updater/2.0' }
    $response = Invoke-WebRequest -Uri "https://github.com/$Repo/releases/latest" -UseBasicParsing -Headers $headers -TimeoutSec 30 -MaximumRedirection 10
    Test-OperationCancelled
    $uri = [string]$response.BaseResponse.ResponseUri.AbsoluteUri
    if ($uri -notmatch '/releases/tag/chatgpt-codex-windows-([0-9.]+)$') {
        Stop-Updater 'BadRelease' @($uri)
    }
    $version = [version]$Matches[1]
    $tag = "chatgpt-codex-windows-$version"
    $arch = Get-NativeArchitecture
    $file = "OpenAI.Codex_${version}_${arch}__2p2nqsd0c76g0.msix"
    $html = (Invoke-WebRequest -Uri "https://github.com/$Repo/releases/expanded_assets/$tag" -UseBasicParsing -Headers $headers -TimeoutSec 30).Content
    Test-OperationCancelled
    $assetPath = "/$Repo/releases/download/$tag/$file"
    if ($html -notmatch ('href="' + [regex]::Escape($assetPath) + '"')) {
        Stop-Updater 'NoAsset' @($arch)
    }
    [pscustomobject]@{
        Version=$version; Architecture=$arch; FileName=$file
        DownloadUrl="https://github.com$assetPath"
        ChecksumUrl="https://github.com/$Repo/releases/download/$tag/SHA256SUMS-windows.txt"
        ReleaseUrl="https://github.com/$Repo/releases/tag/$tag"
    }
}

function Get-InstalledVersion {
    $package = Get-AppxPackage -Name $PackageName -ErrorAction Stop |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($package) { return [version]$package.Version }
    return $null
}

function Get-UpdateState {
    $installed = Get-InstalledVersion
    $latest = Get-LatestRelease
    try { $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { $task=$null }
    [pscustomobject]@{
        Installed=$installed; Latest=$latest
        UpdateAvailable=($null -eq $installed -or $latest.Version -gt $installed)
        MonitorEnabled=($null -ne $task)
    }
}

function Initialize-ParallelDownload {
    if ('ChatGPTUpdater.ParallelDownload' -as [type]) { return }
    Add-Type -AssemblyName System.Net.Http
    Add-Type -ReferencedAssemblies 'System.Net.Http','System.Core','System' -TypeDefinition @'
using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
namespace ChatGPTUpdater {
 public sealed class ParallelDownload : IDisposable {
  readonly HttpClient http;
  long total;
  long[] completed = new long[1];
  int active, peak, channels;
  public long TotalBytes { get { return Interlocked.Read(ref total); } }
  public long ReceivedBytes { get { long sum=0; var c=completed; for(int i=0;i<c.Length;i++) sum+=Interlocked.Read(ref c[i]); return sum; } }
  public int ActiveConnections { get { return Volatile.Read(ref active); } }
  public int PeakConnections { get { return Volatile.Read(ref peak); } }
  public int Connections { get { return Volatile.Read(ref channels); } }
  public ParallelDownload(int connections) {
   ServicePointManager.DefaultConnectionLimit=Math.Max(ServicePointManager.DefaultConnectionLimit,connections);
   var handler=new HttpClientHandler { MaxConnectionsPerServer=connections, AutomaticDecompression=DecompressionMethods.None };
   http=new HttpClient(handler) { Timeout=Timeout.InfiniteTimeSpan };
   http.DefaultRequestHeaders.UserAgent.ParseAdd("ChatGPT-Updater/3.0");
   http.DefaultRequestHeaders.TryAddWithoutValidation("Accept-Encoding","identity");
  }
  void Enter() { int n=Interlocked.Increment(ref active); int p; do { p=peak; if(n<=p)break; } while(Interlocked.CompareExchange(ref peak,n,p)!=p); }
  void Leave() { Interlocked.Decrement(ref active); }
  public Task StartAsync(string url,string path,string hash,int count,CancellationToken token) { return RunAsync(url,path,hash,count,token); }
  async Task RunAsync(string url,string path,string hash,int count,CancellationToken token) {
   bool ranges=false;
   for(int attempt=0;;attempt++) {
    try {
     using(var cts=CancellationTokenSource.CreateLinkedTokenSource(token))
     using(var request=new HttpRequestMessage(HttpMethod.Get,url)) {
      cts.CancelAfter(30000); request.Headers.Range=new RangeHeaderValue(0,0);
      using(var response=await http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,cts.Token).ConfigureAwait(false)) {
       response.EnsureSuccessStatusCode();
       var range=response.Content.Headers.ContentRange;
       ranges=response.StatusCode==HttpStatusCode.PartialContent && range!=null && range.From==0 && range.To==0 && range.Length>0;
       Interlocked.Exchange(ref total,ranges?range.Length.Value:(response.Content.Headers.ContentLength??0));
       if(response.StatusCode!=HttpStatusCode.OK && !ranges) throw new IOException("Invalid range probe response.");
      }
     }
     break;
    } catch { if(token.IsCancellationRequested || attempt>=4)throw; }
    await Task.Delay(1000<<attempt,token).ConfigureAwait(false);
   }
   channels=ranges?(int)Math.Min(count,Math.Max(1,total/(64*1024))):1;
   completed=new long[channels];
   string directory=path+".parts";
   string single=path+".single.part";
   string assembled=path+".assembling";
   string[] parts;
   if(ranges) {
    Directory.CreateDirectory(directory);
    string metadata=Path.Combine(directory,"identity.txt");
    string identity=hash+"|"+total+"|"+channels;
    if(!File.Exists(metadata) || File.ReadAllText(metadata)!=identity) {
     foreach(string old in Directory.GetFiles(directory,"*.part")) File.Delete(old);
     File.WriteAllText(metadata,identity);
    }
    long size=(total+channels-1)/channels;
    parts=Enumerable.Range(0,channels).Select(i=>Path.Combine(directory,i+".part")).ToArray();
    var jobs=Enumerable.Range(0,channels).Select(i=>PartAsync(url,parts[i],i,i*size,Math.Min(total-1,(i+1)*size-1),token)).ToArray();
    await Task.WhenAll(jobs).ConfigureAwait(false);
    token.ThrowIfCancellationRequested();
    using(var output=new FileStream(assembled,FileMode.Create,FileAccess.Write,FileShare.None,1024*1024,true)) {
     foreach(string part in parts) using(var input=new FileStream(part,FileMode.Open,FileAccess.Read,FileShare.Read,1024*1024,true)) {
      await input.CopyToAsync(output,1024*1024,token).ConfigureAwait(false);
     }
    }
   } else {
    parts=new[]{single};
    await SingleAsync(url,single,token).ConfigureAwait(false);
    token.ThrowIfCancellationRequested();
    if(File.Exists(assembled)) File.Delete(assembled);
    File.Copy(single,assembled,true);
   }
   token.ThrowIfCancellationRequested();
   string actual;
   using(var sha=SHA256.Create())
   using(var input=File.OpenRead(assembled)) actual=BitConverter.ToString(sha.ComputeHash(input)).Replace("-","");
   if(!string.Equals(actual,hash,StringComparison.OrdinalIgnoreCase)) {
    File.Delete(assembled);
    foreach(string part in parts) if(File.Exists(part))File.Delete(part);
    throw new IOException("SHA-256 mismatch; invalid fragments discarded.");
   }
   token.ThrowIfCancellationRequested();
   if(File.Exists(path))File.Replace(assembled,path,null); else File.Move(assembled,path);
   foreach(string part in parts) if(File.Exists(part)) File.Delete(part);
   if(ranges) {
    File.Delete(Path.Combine(directory,"identity.txt"));
    if(!Directory.EnumerateFileSystemEntries(directory).Any()) Directory.Delete(directory);
   }
  }
  async Task PartAsync(string url,string path,int index,long start,long end,CancellationToken token) {
   if(File.Exists(path) && new FileInfo(path).Length>end-start+1) File.Delete(path);
   for(int attempt=0;;attempt++) {
    token.ThrowIfCancellationRequested();
    long existing=File.Exists(path)?new FileInfo(path).Length:0;
    Interlocked.Exchange(ref completed[index],existing);
    long from=start+existing;
    if(from>end)return;
    try {
     Enter();
     using(var cts=CancellationTokenSource.CreateLinkedTokenSource(token))
     using(var request=new HttpRequestMessage(HttpMethod.Get,url)) {
      cts.CancelAfter(30000); request.Headers.Range=new RangeHeaderValue(from,end);
      using(var response=await http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,cts.Token).ConfigureAwait(false)) {
       response.EnsureSuccessStatusCode();
       var range=response.Content.Headers.ContentRange;
       if(response.StatusCode!=HttpStatusCode.PartialContent || range==null || range.From!=from || range.To!=end || range.Length!=total)
        throw new IOException("Server returned a different byte range.");
       using(var source=await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
       using(var output=new FileStream(path,FileMode.Append,FileAccess.Write,FileShare.Read,128*1024,true)) {
        byte[] buffer=new byte[128*1024]; long remaining=end-from+1;
        while(remaining>0) {
         cts.CancelAfter(30000);
         int read=await source.ReadAsync(buffer,0,(int)Math.Min(buffer.Length,remaining),cts.Token).ConfigureAwait(false);
         if(read==0)throw new IOException("Download ended early.");
         await output.WriteAsync(buffer,0,read,cts.Token).ConfigureAwait(false);
         remaining-=read; Interlocked.Add(ref completed[index],read);
        }
       }
      }
     }
     return;
    } catch { if(token.IsCancellationRequested || attempt>=4)throw; }
    finally { Leave(); }
    await Task.Delay(1000<<attempt,token).ConfigureAwait(false);
   }
  }
  async Task SingleAsync(string url,string path,CancellationToken token) {
   for(int attempt=0;;attempt++) {
    token.ThrowIfCancellationRequested();
    Interlocked.Exchange(ref completed[0],0);
    try {
     Enter();
     using(var cts=CancellationTokenSource.CreateLinkedTokenSource(token))
     using(var request=new HttpRequestMessage(HttpMethod.Get,url)) {
      cts.CancelAfter(30000);
      using(var response=await http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,cts.Token).ConfigureAwait(false)) {
       response.EnsureSuccessStatusCode();
       if(response.StatusCode!=HttpStatusCode.OK)throw new IOException("Expected full response.");
       if(response.Content.Headers.ContentLength.HasValue) Interlocked.Exchange(ref total,response.Content.Headers.ContentLength.Value);
       using(var source=await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
       using(var output=new FileStream(path,FileMode.Create,FileAccess.Write,FileShare.Read,128*1024,true)) {
        byte[] buffer=new byte[128*1024];
        for(;;) {
         cts.CancelAfter(30000);
         int read=await source.ReadAsync(buffer,0,buffer.Length,cts.Token).ConfigureAwait(false);
         if(read==0)break;
         await output.WriteAsync(buffer,0,read,cts.Token).ConfigureAwait(false);
         Interlocked.Add(ref completed[0],read);
        }
       }
      }
     }
     if(total>0 && ReceivedBytes!=total)throw new IOException("Download ended early.");
     return;
    } catch { if(token.IsCancellationRequested || attempt>=4)throw; }
    finally { Leave(); }
    await Task.Delay(1000<<attempt,token).ConfigureAwait(false);
   }
  }
  public void Dispose() { http.Dispose(); }
 }
}
'@
}

function Get-Aria2Path {
    $candidate = Join-Path $DataDir 'tools\aria2c.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    $command = Get-Command aria2c.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Save-Aria2Package {
    param([string]$Executable,[string]$Url,[string]$Path,[string]$ExpectedHash)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = 'Hidden'
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $arguments = @(
        '--no-conf=true','--no-netrc=true','--check-certificate=true','--min-tls-version=TLSv1.2',
        '--continue=true','--auto-file-renaming=false','--allow-overwrite=true',
        '--file-allocation=none','--auto-save-interval=1','--max-tries=5','--retry-wait=2',
        '--connect-timeout=20','--timeout=30','--enable-color=false','--show-console-readout=false',
        '--summary-interval=1',('--stop-with-process='+$PID),
        ('--split='+$Connections),('--max-connection-per-server='+$Connections),'--min-split-size=1M',
        ('--checksum=sha-256='+$ExpectedHash),
        ('--dir="'+(Split-Path -Parent $Path)+'"'),('--out="'+[IO.Path]::GetFileName($Path)+'"'),
        ('"'+$Url+'"')
    )
    $info.Arguments = $arguments -join ' '
    $process = [Diagnostics.Process]::Start($info)
    $errorTask = $process.StandardError.ReadToEndAsync()
    $lineTask = $process.StandardOutput.ReadLineAsync()
    $recent = New-Object 'Collections.Generic.Queue[string]'
    try {
        while (-not $process.HasExited) {
            Test-OperationCancelled
            if ($lineTask.IsCompleted) {
                $line = $lineTask.GetAwaiter().GetResult()
                if ($null -ne $line) {
                    $recent.Enqueue($line)
                    if ($recent.Count -gt 20) { [void]$recent.Dequeue() }
                    if ($line -match '\((\d+)%\)') {
                        Report-OperationProgress 'AriaProgress' ([int]([int]$Matches[1]*0.75)) @($Matches[1])
                    }
                    $lineTask = $process.StandardOutput.ReadLineAsync()
                }
            }
            Start-Sleep -Milliseconds 150
        }
        # Drain stdout concurrently with stderr before checking the result.
        $lastLine=$lineTask.GetAwaiter().GetResult()
        $tail=$process.StandardOutput.ReadToEnd()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $diagnostic=($errorText+[Environment]::NewLine+($recent.ToArray()-join [Environment]::NewLine)+[Environment]::NewLine+$lastLine+$tail).Trim()
            Stop-Updater 'AriaFailed' @($process.ExitCode,$diagnostic)
        }
    } finally {
        if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(2000) }
        $process.Dispose()
    }
}

function Save-ParallelPackage {
    param([string]$Url,[string]$Path,[string]$ExpectedHash)
    Test-OperationCancelled
    $aria = if ($Downloader -ne 'BuiltIn') { Get-Aria2Path } else { $null }
    if ($Downloader -eq 'Aria2' -and -not $aria) { Stop-Updater 'AriaMissing' }
    if ($aria) {
        Write-Log (Get-Text 'DownloadEngine' @('aria2',$Connections))
        Report-OperationProgress 'DownloadWaiting'
        Save-Aria2Package -Executable $aria -Url $Url -Path $Path -ExpectedHash $ExpectedHash
        return
    }
    Write-Log (Get-Text 'DownloadEngine' @('.NET HttpClient',$Connections))
    Report-OperationProgress 'DownloadWaiting'
    Initialize-ParallelDownload
    $engine = New-Object ChatGPTUpdater.ParallelDownload($Connections)
    $cancellation = New-Object Threading.CancellationTokenSource
    $task = $engine.StartAsync($Url,$Path,$ExpectedHash,$Connections,$cancellation.Token)
    $fallbackReported = $false
    try {
        while (-not $task.IsCompleted) {
            if ($ResultPath -and (Test-Path -LiteralPath ($ResultPath+'.cancel'))) { $cancellation.Cancel() }
            if ($engine.Connections -eq 1 -and $Connections -gt 1 -and -not $fallbackReported) {
                Write-Log (Get-Text 'RangeFallback'); $fallbackReported=$true
            }
            if ($engine.TotalBytes -gt 0) {
                $percent = [int][math]::Min(75,[math]::Floor($engine.ReceivedBytes*75.0/$engine.TotalBytes))
                Report-OperationProgress 'Download' $percent @(
                    ([math]::Min(100,$engine.ReceivedBytes*100.0/$engine.TotalBytes).ToString('F1')),
                    (($engine.ReceivedBytes/1MB).ToString('F1')),(($engine.TotalBytes/1MB).ToString('F1')),$engine.Connections)
            }
            Start-Sleep -Milliseconds 200
        }
        if ($cancellation.IsCancellationRequested) { Stop-Updater 'Cancelled' }
        try { [void]$task.GetAwaiter().GetResult() } catch { Stop-Updater 'DownloadFailed' @($_.Exception.GetBaseException().Message) }
    } finally {
        $cancellation.Cancel()
        # Allow streams to flush before disposing the HTTP client; fragments remain resumable.
        try { [void]$task.Wait(5000) } catch { }
        $engine.Dispose()
        $cancellation.Dispose()
    }
}

function Save-ReleasePackage {
    param([Parameter(Mandatory)]$Release)
    [void][IO.Directory]::CreateDirectory($DownloadDir)
    $path = Join-Path $DownloadDir $Release.FileName
    Test-OperationCancelled
    Report-OperationProgress 'Checksum' 0
    $sums = (Invoke-WebRequest -Uri $Release.ChecksumUrl -UseBasicParsing -TimeoutSec 30).Content
    $match = [regex]::Match($sums, ('(?im)^(?<hash>[0-9a-f]{64})\s+\*?' + [regex]::Escape($Release.FileName) + '\s*$'))
    if (-not $match.Success) { Stop-Updater 'NoChecksum' }
    $expectedHash = $match.Groups['hash'].Value.ToUpperInvariant()
    $reuse = (Test-Path -LiteralPath $path) -and ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $expectedHash)
    if (-not $reuse) {
        Save-ParallelPackage -Url $Release.DownloadUrl -Path $path -ExpectedHash $expectedHash
    } else { Write-Log (Get-Text 'Reuse') }

    Test-OperationCancelled
    Report-OperationProgress 'Verifying' 80
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expectedHash) { Stop-Updater 'HashFailed' }
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -ne $ExpectedPublisher) {
        Stop-Updater 'SignatureFailed' @($signature.Status)
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($path)
    try {
        $entry = $archive.GetEntry('AppxManifest.xml')
        if (-not $entry) { Stop-Updater 'ManifestMissing' }
        $reader = New-Object IO.StreamReader($entry.Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
    $identity = $manifest.Package.Identity
    if ($identity.Name -ne $PackageName -or $identity.Publisher -ne $ExpectedPublisher -or
        [version]$identity.Version -ne $Release.Version -or $identity.ProcessorArchitecture -ne $Release.Architecture) {
        Stop-Updater 'IdentityFailed'
    }
    Write-Log (Get-Text 'Verified')
    return $path
}

function Install-LatestUpdate {
    $state = Get-UpdateState
    if (-not $state.UpdateAvailable) { Write-Log (Get-Text 'NoUpdate' @($state.Installed)); return $state }
    $path = Save-ReleasePackage $state.Latest
    Test-OperationCancelled
    Report-OperationProgress 'Installing' 95
    Add-AppxPackage -Path $path -ForceTargetApplicationShutdown -ErrorAction Stop
    $installed = Get-InstalledVersion
    if ($installed -ne $state.Latest.Version) { Stop-Updater 'VersionFailed' @($installed,$state.Latest.Version) }
    $state.Installed = $installed
    $state.UpdateAvailable = $false
    Report-OperationProgress 'Installed' 100 @($installed)
    if (-not $Silent) { Write-Progress -Activity (Get-Text 'Heading') -Completed }
    return $state
}

function Install-MonitorTask {
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Monitor{1} -Language {2} -Connections {3} -Downloader {4}' -f $script:ScriptPath, $(if ($AutoInstall) { ' -AutoInstall' } else { '' }),'Auto',$Connections,$Downloader
    $action = New-ScheduledTaskAction -Execute $WindowsPowerShell -Argument $arguments -WorkingDirectory (Split-Path -Parent $script:ScriptPath)
    $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($Hour))
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description 'Checks signed ChatGPT desktop updates.' -Force | Out-Null
    Write-Log (Get-Text 'MonitorSaved' @($Hour.ToString('00'),[bool]$AutoInstall))
}

function Remove-MonitorTask {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) { $task | Unregister-ScheduledTask -Confirm:$false }
    Write-Log (Get-Text 'MonitorOff')
}

function Show-Notification {
    param([string]$Message)
    if ($Silent) { return }
    Add-Type -AssemblyName System.Windows.Forms
    $icon = New-Object System.Windows.Forms.NotifyIcon
    try {
        $icon.Icon = [Drawing.SystemIcons]::Information
        $icon.BalloonTipTitle = Get-Text 'Notification'
        $icon.BalloonTipText = $Message
        $icon.Visible = $true
        $icon.ShowBalloonTip(8000)
        Start-Sleep -Seconds 8
    } finally { $icon.Dispose() }
}

function Test-IsAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Repair-ChatGPTUpdate {
    if (-not (Test-IsAdministrator)) {
        if ($Silent -or $ElevatedOnce) { Stop-Updater 'NeedAdmin' }
        Write-Log (Get-Text 'RequestAdmin')
        $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode Repair -ElevatedOnce -Language {1}' -f $script:ScriptPath,$script:Language
        $child = Start-Process -FilePath $WindowsPowerShell -ArgumentList $arguments -Verb RunAs -Wait -PassThru -WindowStyle Hidden
        if ($child.ExitCode -ne 0) { Stop-Updater 'AdminFailed' @($child.ExitCode) }
        Write-Log (Get-Text 'AdminDone')
        return
    }
    $backupDir = Join-Path $env:ProgramData 'ChatGPTUpdater\repair-backups'
    [void][IO.Directory]::CreateDirectory($backupDir)
    $result = Join-Path $backupDir 'repair-result.txt'
    try {
        $dll = Join-Path $env:SystemRoot 'System32\dosvc.dll'
        if (-not (Test-Path -LiteralPath $dll)) { Stop-Updater 'DllMissing' @($dll) }
        $backup = Join-Path $backupDir ('DoSvc-{0}.reg' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
        & reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\DoSvc' $backup /y *> $null
        if ($LASTEXITCODE -ne 0) { Stop-Updater 'BackupFailed' }
        & reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Services\DoSvc\Parameters' /v ServiceDll /t REG_EXPAND_SZ /d '%SystemRoot%\System32\dosvc.dll' /f *> $null
        if ($LASTEXITCODE -ne 0) { Stop-Updater 'DllWriteFailed' }
        & reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Services\DoSvc\Parameters' /v ServiceDllUnloadOnStop /t REG_DWORD /d 1 /f *> $null
        if ($LASTEXITCODE -ne 0) { Stop-Updater 'UnloadWriteFailed' }
        Start-Service DoSvc -ErrorAction Stop
        Start-Service BITS -ErrorAction Stop
        $svc = Get-Service DoSvc
        if ($svc.Status -ne 'Running') { Stop-Updater 'ServiceStopped' }
        @('SUCCESS',"Backup=$backup","DoSvcStatus=$($svc.Status)") | Set-Content -LiteralPath $result -Encoding UTF8
        Write-Log (Get-Text 'Repaired' @($backup))
    } catch {
        @('FAILED',$_.Exception.ToString()) | Set-Content -LiteralPath $result -Encoding UTF8
        throw
    }
}

function Invoke-ExclusiveOperation {
    param([scriptblock]$Operation)
    $mutex = New-Object Threading.Mutex($false, 'Local\ChatGPTUpdater.Maintenance')
    $held = $false
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { Stop-Updater 'Locked' }
        & $Operation
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-UpdaterAction {
    param([string]$Action)
    switch ($Action) {
        { $_ -in 'Check','Status' } {
            $state = Get-UpdateState
            $local = if ($state.Installed) { [string]$state.Installed } else { Get-Text 'NotInstalled' }
            Write-Log (Get-Text 'State' @($local,$state.Latest.Version,$state.UpdateAvailable,$state.MonitorEnabled))
            return $state
        }
        'Update' { return Invoke-ExclusiveOperation { Install-LatestUpdate } }
        'InstallMonitor' { Install-MonitorTask }
        'RemoveMonitor' { Remove-MonitorTask }
        'Repair' {
            if (Test-IsAdministrator) { Invoke-ExclusiveOperation { Repair-ChatGPTUpdate } }
            else { Repair-ChatGPTUpdate }
        }
        'Monitor' {
            $state = Get-UpdateState
            Write-Log (Get-Text 'Scheduled' @($state.Installed,$state.Latest.Version))
            if ($state.UpdateAvailable) {
                if ($AutoInstall) { return Invoke-ExclusiveOperation { Install-LatestUpdate } }
                Show-Notification (Get-Text 'Reminder' @($state.Latest.Version))
            }
            return $state
        }
        default { Stop-Updater 'Unknown' @($Action) }
    }
}


function Show-Tui {
    :MenuLoop while ($true) {
        Write-Host ''
        Write-Host ('===== {0} =====' -f (Get-Text 'Title'))
        foreach ($key in 'Tui1','Tui2') { Write-Host (Get-Text $key) }
        Write-Host (Get-Text 'Tui3' @($Hour.ToString('00')))
        foreach ($key in 'Tui4','Tui5','Tui6','Tui0') { Write-Host (Get-Text $key) }
        $choice = Read-Host (Get-Text 'Choose')
        if ($null -eq $choice -or $choice -eq '0') { return }
        try {
            switch ($choice.Trim()) {
                '1' { [void](Invoke-UpdaterAction 'Check') }
                '2' { if ((Read-Host (Get-Text 'TuiUpdate')) -eq 'Y') { [void](Invoke-UpdaterAction 'Update') } }
                '3' { [void](Invoke-UpdaterAction 'InstallMonitor') }
                '4' { [void](Invoke-UpdaterAction 'RemoveMonitor') }
                '5' { if ((Read-Host (Get-Text 'TuiRepair')) -eq 'Y') { [void](Invoke-UpdaterAction 'Repair') } }
                '6' { Set-AppLanguage $(if ($script:Language -eq 'zh-CN') {'en-US'}else{'zh-CN'}) -Persist; continue MenuLoop }
                default { Write-Host (Get-Text 'TuiInvalid') }
            }
        } catch { Write-Log $_.Exception.Message 'ERROR' }
        [void](Read-Host (Get-Text 'Enter'))
    }
}

function Initialize-Wpf {
    # Opt in before loading WPF: render at each monitor's DPI, with no bitmap stretching.
    [AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false)
    [AppContext]::SetSwitch('Switch.System.Windows.DoNotUsePresentationDpiCapabilityTier2OrGreater', $false)
    if (-not ('ChatGPTUpdater.NativeDpi' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ChatGPTUpdater {
    public static class NativeDpi {
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern IntPtr GetWindowDpiAwarenessContext(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool AreDpiAwarenessContextsEqual(IntPtr a, IntPtr b);
        [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int awareness);
        public static void Enable() {
            try {
                SetProcessDpiAwarenessContext(new IntPtr(-4));
                SetThreadDpiAwarenessContext(new IntPtr(-4));
            } catch (EntryPointNotFoundException) { SetProcessDpiAwareness(2); }
        }
    }
}
'@
    }
    [ChatGPTUpdater.NativeDpi]::Enable()
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
}

function New-UpdaterWindow {
    Initialize-Wpf
    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="620" Height="540" MinWidth="560" MinHeight="520" WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True" SnapsToDevicePixels="True" FontSize="14"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="Auto"
        Foreground="{DynamicResource {x:Static SystemColors.WindowTextBrushKey}}"
        Background="{DynamicResource {x:Static SystemColors.WindowBrushKey}}">
  <Grid Margin="24" Background="{DynamicResource {x:Static SystemColors.WindowBrushKey}}">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid Margin="0,0,0,20">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel Margin="0,0,10,0">
        <TextBlock x:Name="HeadingText" FontSize="24" FontWeight="SemiBold"/>
        <TextBlock x:Name="SubtitleText" Margin="0,6,0,0" TextWrapping="Wrap"/>
      </StackPanel>
      <ComboBox x:Name="LanguageChoice" Grid.Column="1" Width="112" VerticalAlignment="Top"
                AutomationProperties.Name="Language / 语言"/>
    </Grid>
    <Grid Grid.Row="1" Margin="0,0,0,18">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <TextBlock x:Name="LocalLabel" Margin="0,0,24,10"/>
      <TextBlock x:Name="LocalVersion" Grid.Column="1" Margin="0,0,0,10" FontWeight="SemiBold"/>
      <TextBlock x:Name="OnlineLabel" Grid.Row="1" Margin="0,0,24,0"/>
      <TextBlock x:Name="OnlineVersion" Grid.Row="1" Grid.Column="1" FontWeight="SemiBold"/>
    </Grid>
    <WrapPanel Grid.Row="2" Margin="0,0,0,18">
      <Button x:Name="CheckButton" Padding="14,7" Margin="0,0,10,0"/>
      <Button x:Name="UpdateButton" Padding="14,7" IsEnabled="False"/>
    </WrapPanel>
    <WrapPanel Grid.Row="3" Margin="0,0,0,14" VerticalAlignment="Center">
      <TextBlock x:Name="ConnectionsLabel" VerticalAlignment="Center" Margin="0,0,12,0"/>
      <ComboBox x:Name="ConnectionsChoice" Width="72" VerticalContentAlignment="Center"/>
    </WrapPanel>
    <WrapPanel Grid.Row="4" Margin="0,0,0,14" VerticalAlignment="Center">
      <CheckBox x:Name="MonitorCheck" VerticalAlignment="Center" Margin="0,0,14,0"/>
      <ComboBox x:Name="HourChoice" Width="88" VerticalContentAlignment="Center" Margin="0,0,10,0"/>
      <Button x:Name="SaveMonitorButton" Padding="12,4"/>
    </WrapPanel>
    <StackPanel Grid.Row="5">
      <TextBlock x:Name="StatusText" TextWrapping="Wrap" Margin="0,0,0,10"/>
      <ProgressBar x:Name="OperationProgress" Height="5" Minimum="0" Maximum="100" Visibility="Collapsed"/>
    </StackPanel>
    <Grid Grid.Row="6" Margin="0,14,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="FooterText" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,16,0"/>
      <Button x:Name="RepairButton" Grid.Column="1" Padding="10,5"/>
    </Grid>
  </Grid>
</Window>
'@
    $reader = New-Object Xml.XmlNodeReader($xaml)
    try { return [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
}

function Show-UpdaterGui {
    $window = New-UpdaterWindow
    $ui = @{}
    foreach ($name in 'HeadingText','SubtitleText','LocalLabel','OnlineLabel','FooterText','LocalVersion',
        'OnlineVersion','CheckButton','UpdateButton','MonitorCheck','HourChoice','SaveMonitorButton',
        'StatusText','OperationProgress','RepairButton','LanguageChoice','ConnectionsChoice','ConnectionsLabel') {
        $ui[$name]=$window.FindName($name)
    }
    [void]$ui.LanguageChoice.Items.Add('简体中文')
    [void]$ui.LanguageChoice.Items.Add('English')
    $ui.LanguageChoice.SelectedIndex = if ($script:Language -eq 'zh-CN') {0}else{1}
    foreach ($n in 1..16) { [void]$ui.ConnectionsChoice.Items.Add($n) }
    $ui.ConnectionsChoice.SelectedItem=$Connections
    0..23 | ForEach-Object { [void]$ui.HourChoice.Items.Add(('{0:00}:00' -f $_)) }
    $ui.HourChoice.SelectedIndex=$Hour
    try{$task=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue}catch{$task=$null}
    $ui.MonitorCheck.IsChecked=($null -ne $task)
    if ($task -and $task.Triggers -and $task.Triggers[0].StartBoundary) {
        $ui.HourChoice.SelectedIndex=([datetime]$task.Triggers[0].StartBoundary).Hour
    }
    $context=@{ Process=$null; Result=$null; Action=$null; State=$null; Timer=$null; Busy=$false;
        StatusKey='Ready'; StatusValues=@(); ErrorText=$null; Progress=$null; Local=$null; LocalError=$false }
    try { $context.Local=Get-InstalledVersion } catch { $context.LocalError=$true }
    $applyLanguage = {
        $window.Title=Get-Text 'Title'
        $window.FontFamily=if($script:Language -eq 'zh-CN'){'Microsoft YaHei UI'}else{'Segoe UI'}
        $labels=@{HeadingText='Heading'; SubtitleText='Subtitle';LocalLabel='Local';OnlineLabel='Online';
            ConnectionsLabel='Connections';FooterText='Footer'}
        foreach ($name in $labels.Keys) { $ui[$name].Text=Get-Text $labels[$name] }
        foreach ($item in @(@('CheckButton','CheckButton'),@('MonitorCheck','MonitorCheck'),@('SaveMonitorButton','Apply'),@('RepairButton','RepairButton'))) {
            $ui[$item[0]].Content=Get-Text $item[1]
        }
        $ui.LocalVersion.Text=if($context.LocalError){Get-Text 'ReadFailed'}elseif($context.Local){[string]$context.Local}else{Get-Text 'NotInstalled'}
        $ui.OnlineVersion.Text=if($context.State){$context.State.Latest}else{Get-Text 'NotChecked'}
        $ui.UpdateButton.Content=Get-Text $(if($context.Local){'UpdateButton'}else{'InstallButton'})
        $ui.StatusText.Text=if($context.ErrorText){$context.ErrorText}else{Get-Text $context.StatusKey $context.StatusValues}
    }
    $setBusy = {
        param([bool]$busy)
        $context.Busy=$busy
        foreach ($name in 'CheckButton','MonitorCheck','HourChoice','ConnectionsChoice','SaveMonitorButton','RepairButton') {
            $ui[$name].IsEnabled=-not $busy
        }
        $ui.UpdateButton.IsEnabled=(-not $busy -and $context.State -and $context.State.UpdateAvailable)
        $ui.OperationProgress.Visibility=if($busy){'Visible'}else{'Collapsed'}
        $ui.OperationProgress.IsIndeterminate=$busy
    }
    & $applyLanguage
    $ui.LanguageChoice.Add_SelectionChanged({
        Set-AppLanguage $(if($ui.LanguageChoice.SelectedIndex -eq 0){'zh-CN'}else{'en-US'}) -Persist
        & $applyLanguage
    })
    $start = {
        param([string]$action)
        if($context.Busy){return}
        try {
            $operations=Join-Path $DataDir 'operations'
            [void][IO.Directory]::CreateDirectory($operations)
            $result=Join-Path $operations ([guid]::NewGuid().ToString('N')+'.json')
            $arguments='-NoLogo -NoProfile -Sta -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode {1} -Silent -ResultPath "{2}" -Hour {3} -Language {4} -Connections {5} -Downloader {6}' -f $script:ScriptPath,$action,$result,$ui.HourChoice.SelectedIndex,$script:Language,$ui.ConnectionsChoice.SelectedItem,$Downloader
            $info=New-Object Diagnostics.ProcessStartInfo
            $info.FileName=$WindowsPowerShell; $info.Arguments=$arguments; $info.WindowStyle='Hidden'
            if($action -eq 'Repair' -and -not(Test-IsAdministrator)) {
                $info.UseShellExecute=$true; $info.Verb='runas'; $info.Arguments+=' -ElevatedOnce'
            }else{ $info.UseShellExecute=$false; $info.CreateNoWindow=$true }
            $context.Process=[Diagnostics.Process]::Start($info)
            $context.Result=$result; $context.Action=$action; $context.ErrorText=$null
            $context.StatusKey='Busy'; $context.StatusValues=@()
            & $setBusy $true
            & $applyLanguage
            $context.Timer.Start()
        }catch{
            $context.ErrorText=Get-Text 'LaunchFailed' @($_.Exception.Message)
            & $setBusy $false
            & $applyLanguage
        }
    }
    $timer=New-Object Windows.Threading.DispatcherTimer
    $context.Timer=$timer
    $timer.Interval=[TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        try {
            $progressFile=$context.Result+'.progress'
            if(Test-Path -LiteralPath $progressFile) {
                try {
                    $progress=Get-Content -LiteralPath $progressFile -Raw | ConvertFrom-Json
                    $context.StatusKey=$progress.Key; $context.StatusValues=@($progress.Values)
                    $ui.StatusText.Text=Get-Text $context.StatusKey $context.StatusValues
                    $ui.OperationProgress.IsIndeterminate=($progress.Percent -lt 0)
                    if($progress.Percent -ge 0){$ui.OperationProgress.Value=$progress.Percent}
                }catch{}
            }
            if(-not $context.Process.HasExited){return}
            $timer.Stop()
            $result=if(Test-Path -LiteralPath $context.Result){Get-Content -LiteralPath $context.Result -Raw | ConvertFrom-Json}else{$null}
            $context.StatusValues=@(); $context.ErrorText=$null
            if(-not $result -or -not $result.Success) {
                if($result -and $result.TextKey){
                    $context.StatusKey=$result.TextKey; $context.StatusValues=@($result.TextValues)
                }else{
                    $context.ErrorText=if($result){$result.Message}else{Get-Text 'Incomplete' @($context.Process.ExitCode)}
                }
            }elseif($result.State){
                $context.State=$result.State; $context.Local=$result.State.Installed
                $context.StatusKey=if($result.State.UpdateAvailable){'Available'}else{'Current'}
            }else{ $context.StatusKey=$result.TextKey }
            & $applyLanguage
        }catch{
            $timer.Stop()
            $context.ErrorText=Get-Text 'OperationFailed' @($_.Exception.Message)
            & $applyLanguage
        }finally{
            if($context.Process -and $context.Process.HasExited) {
                $context.Process.Dispose(); $context.Process=$null
                foreach($p in @($context.Result,($context.Result+'.progress'))) {
                    if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue}
                }
                & $setBusy $false
            }
        }
    })
    $ui.CheckButton.Add_Click({ & $start 'Check' })
    $ui.UpdateButton.Add_Click({
        if([Windows.MessageBox]::Show($window,(Get-Text 'ConfirmUpdate'),(Get-Text 'UpdateButton'),'YesNo','Question') -eq 'Yes'){& $start 'Update'}
    })
    $ui.SaveMonitorButton.Add_Click({if($ui.MonitorCheck.IsChecked){& $start 'InstallMonitor'}else{& $start 'RemoveMonitor'}})
    $ui.RepairButton.Add_Click({
        if([Windows.MessageBox]::Show($window,(Get-Text 'ConfirmRepair'),(Get-Text 'RepairButton'),'YesNo','Warning') -eq 'Yes'){& $start 'Repair'}
    })
    $window.Add_ContentRendered({if(-not $context.State -and -not $context.Busy){& $start 'Check'}})
    $window.Add_Closing({
        $timer.Stop()
        # Closing never waits for network I/O or prevents the window from closing.
        if($context.Process -and -not $context.Process.HasExited) {
            if($context.Action -in 'Check','Status'){
                try{$context.Process.Kill()}catch{}
            }elseif($context.Action -eq 'Update'){
                try{[IO.File]::WriteAllText(($context.Result+'.cancel'),'cancel')}catch{}
            }
            # Installation/repair commits finish in the hidden worker; do not interrupt Windows servicing.
        }
    })
    try{[void]$window.ShowDialog()}finally{
        $timer.Stop()
        if($context.Process){
            $exited=$context.Process.HasExited
            $context.Process.Dispose(); $context.Process=$null
            if($exited -or $context.Action -in 'Check','Status'){
                foreach($p in @($context.Result,($context.Result+'.progress'))){
                    if($p -and (Test-Path -LiteralPath $p)){Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue}
                }
            }
        }
    }
}

function Write-OperationResult {
    param([bool]$Success,[string]$Message,$State,[string]$TextKey,[object[]]$TextValues=@())
    if (-not $ResultPath) { return }
    $summary = $null
    if ($State -and $State.PSObject.Properties['Latest']) {
        $summary = @{
            Installed=$(if ($State.Installed) { [string]$State.Installed } else { $null })
            Latest=[string]$State.Latest.Version
            UpdateAvailable=[bool]$State.UpdateAvailable
            MonitorEnabled=[bool]$State.MonitorEnabled
        }
    }
    @{ Success=$Success; Message=$Message; State=$summary; TextKey=$TextKey; TextValues=$TextValues } | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8
}

# Dot-sourcing exposes the functions without launching an interface or running an action.
if ($MyInvocation.InvocationName -eq '.') { return }
$exitCode = 0
try {
    if ($Tui) {
        if ($Mode -and $Mode -ne 'Menu') { Stop-Updater 'TuiConflict' }
        $Mode = 'Menu'
    }
    if (-not $Mode) {
        if ($Silent) { Stop-Updater 'SilentAction' }
        $Mode = 'Gui'
    }
    if ($Silent -and $Mode -in 'Gui','Menu') { Stop-Updater 'SilentUi' }
    if ($AutoInstall -and $Mode -notin 'InstallMonitor','Monitor') { Stop-Updater 'AutoInstallAction' }
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or ($Mode -eq 'Gui' -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA')) {
        if ($HostRestarted) { Stop-Updater 'Host' }
        $forward = @('-NoLogo','-NoProfile','-Sta','-ExecutionPolicy','Bypass','-File',$script:ScriptPath,'-Mode',$Mode,'-HostRestarted','-Hour',[string]$Hour)
        if ($Silent) { $forward += '-Silent' }
        if ($AutoInstall) { $forward += '-AutoInstall' }
        if ($ElevatedOnce) { $forward += '-ElevatedOnce' }
        if ($ResultPath) { $forward += @('-ResultPath',$ResultPath) }
        $forward += @('-Language',$script:Language,'-Connections',[string]$Connections,'-Downloader',$Downloader)
        & $WindowsPowerShell @forward
        exit $LASTEXITCODE
    }
    switch ($Mode) {
        'Gui' { Show-UpdaterGui }
        'Menu' { Show-Tui }
        default {
            $state = Invoke-UpdaterAction $Mode
            $key = switch ($Mode) {
                'InstallMonitor' { 'SettingsSaved' }
                'RemoveMonitor' { 'MonitorOff' }
                'Repair' { 'RepairDone' }
                default { 'Done' }
            }
            Write-OperationResult $true (Get-Text $key) $state $key
            if ($Mode -eq 'Check' -and $state.UpdateAvailable) { $exitCode = 10 }
        }
    }
} catch {
    $message = $_.Exception.Message
    try { Write-Log $message 'ERROR' } catch { if (-not $Silent) { Write-Host $message -ForegroundColor Red } }
    $errorKey = $_.Exception.Data['TextKey']
    $errorValues = $_.Exception.Data['TextValues']
    try { Write-OperationResult $false $message $null $errorKey $errorValues } catch { }
    $exitCode = if ($errorKey -eq 'Cancelled') {2}else{1}
}
if ($ResultPath -and (Test-Path -LiteralPath ($ResultPath+'.cancel'))) { Remove-Item -LiteralPath ($ResultPath+'.cancel') -Force -ErrorAction SilentlyContinue }
exit $exitCode
