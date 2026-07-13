# UTF-8 Encoding
$OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "   Open Design Windows ARM64 Repackager Script" -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan

# 1. Setup paths
$WORKSPACE_ROOT = Split-Path $PSScriptRoot -Parent
$TMP_DIR = Join-Path $WORKSPACE_ROOT ".tmp\repackage-ps1"
$CACHE_DIR = Join-Path $TMP_DIR "cache"
$WORK_DIR = Join-Path $TMP_DIR "work"

$UNPACK_X64_DIR = Join-Path $WORK_DIR "x64-app"
$UNPACK_ELECTRON_DIR = Join-Path $WORK_DIR "electron-arm64"
$UNPACK_BETTER_SQLITE3_DIR = Join-Path $WORK_DIR "better-sqlite3"
$UNPACK_PTY_DIR = Join-Path $WORK_DIR "node-pty-npm"
$ASSEMBLED_DIR = Join-Path $WORK_DIR "assembled"

# Ensure directories exist
New-Item -ItemType Directory -Force -Path $CACHE_DIR | Out-Null
New-Item -ItemType Directory -Force -Path $WORK_DIR | Out-Null

# Helper to download file
function Download-File {
    param (
        [string]$Url,
        [string]$OutPath,
        [bool]$UseProxy,
        [int]$ProxyPort,
        [int]$MaxRetries = 10,
        [int]$ConnectTimeout = 15
    )
    if (Test-Path $OutPath) {
        Write-Host "[缓存命中] $OutPath" -ForegroundColor Gray
        return
    }
    $parent = Split-Path $OutPath -Parent
    if (!(Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $tempPath = "$OutPath.tmp"
    
    $curlArgs = @()
    if ($UseProxy) {
        $curlArgs += "--proxy"
        $curlArgs += "http://127.0.0.1:$ProxyPort"
    }
    $curlArgs += "--connect-timeout"
    $curlArgs += "$ConnectTimeout"
    $curlArgs += "--max-time"
    $curlArgs += "300"
    $curlArgs += "-C"
    $curlArgs += "-"
    $curlArgs += "-L"
    $curlArgs += "--retry"
    $curlArgs += "3"
    $curlArgs += "--retry-delay"
    $curlArgs += "2"
    $curlArgs += "-o"
    $curlArgs += "`"$tempPath`""
    $curlArgs += "`"$Url`""

    $success = $false
    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Host "正在下载 $Url -> 尝试 $i/$MaxRetries..."
        $process = Start-Process -FilePath "C:\Windows\System32\curl.exe" -ArgumentList $curlArgs -Wait -NoNewWindow -PassThru
        if ($process.ExitCode -eq 0) {
            $success = $true
            break
        } else {
            Write-Warning "下载尝试 $i 失败，错误码 $($process.ExitCode)。"
            if ($i -lt $MaxRetries) {
                Start-Sleep -Seconds 3
            }
        }
    }
    if (!$success) {
        if (Test-Path $tempPath) {
            Remove-Item $tempPath -Force
        }
        throw "下载失败，URL: $Url"
    }
    Move-Item -Path $tempPath -Destination $OutPath -Force
    Write-Host "下载完成并保存到 $OutPath" -ForegroundColor Green
}

# Helper to extract using tar.exe
function Extract-Archive {
    param (
        [string]$ArchivePath,
        [string]$TargetDir
    )
    Write-Host "正在解压 $ArchivePath 到 $TargetDir ..."
    if (Test-Path $TargetDir) {
        Remove-Item $TargetDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    
    $tarXfArgs = @("-xf", "`"$ArchivePath`"", "-C", "`"$TargetDir`"")
    $process = Start-Process -FilePath "C:\Windows\System32\tar.exe" -ArgumentList $tarXfArgs -Wait -NoNewWindow -PassThru
    if ($process.ExitCode -ne 0) {
        throw "解压失败，档案: $ArchivePath"
    }
}

# 2. Interactive Proxy Configuration
$portInput = Read-Host "请输入本地代理端口号 (如 7890，直接按回车跳过)"
$useProxy = $false
$proxyPort = 0

if ($portInput.Trim() -ne "") {
    if ([int]::TryParse($portInput.Trim(), [ref]$proxyPort)) {
        Write-Host "正在测试本地代理 127.0.0.1:$proxyPort ..."
        $socket = New-Object System.Net.Sockets.TcpClient
        $connect = $socket.BeginConnect("127.0.0.1", $proxyPort, $null, $null)
        $wait = $connect.AsyncWaitHandle.WaitOne(800, $false)
        if ($wait -and $socket.Connected) {
            $socket.EndConnect($connect)
            $socket.Close()
            Write-Host "本地代理测试成功！将使用本地代理 127.0.0.1:$proxyPort 进行下载。" -ForegroundColor Green
            $useProxy = $true
        } else {
            $socket.Close()
            Write-Host "本地代理连接失败！将自动使用在线加速代理。" -ForegroundColor Yellow
        }
    } else {
        Write-Host "输入端口无效。已跳过本地代理测试，将自动使用在线加速代理。" -ForegroundColor Yellow
    }
} else {
    Write-Host "未输入端口。已跳过本地代理测试，将自动使用在线加速代理。" -ForegroundColor Yellow
}

$gitHubPrefix = ""
if (!$useProxy) {
    $gitHubPrefix = "https://gh.llkk.cc/"
}

# 3. Dynamic Version Detection
$tag = $null
$VERSION = $null

# Attempt 1: GitHub API
try {
    $apiUri = "https://api.github.com/repos/nexu-io/open-design/releases/latest"
    Write-Host "正在通过 API 获取 Open Design 最新发布版本..."
    if ($useProxy) {
        $apiRes = Invoke-RestMethod -Uri $apiUri -Proxy "http://127.0.0.1:$proxyPort" -TimeoutSec 10
    } else {
        $apiRes = Invoke-RestMethod -Uri $apiUri -TimeoutSec 10
    }
    $tag = $apiRes.tag_name
    Write-Host "成功获取最新 Release 标签: $tag" -ForegroundColor Green
} catch {
    Write-Warning "通过 API 获取最新版本失败: $_.Exception.Message"
}

# Attempt 2: HTTP Redirect
if ($null -eq $tag) {
    try {
        Write-Host "正在通过 HTTP 重定向检测最新版本..."
        $req = [System.Net.WebRequest]::Create("https://github.com/nexu-io/open-design/releases/latest")
        $req.AllowAutoRedirect = $false
        $req.Timeout = 10000
        if ($useProxy) {
            $req.Proxy = New-Object System.Net.WebProxy("127.0.0.1", $proxyPort)
        }
        $res = $req.GetResponse()
        $loc = $res.Headers["Location"]
        $res.Close()
        if ($loc -and $loc -match '/tag/(.+)$') {
            $tag = $Matches[1]
            Write-Host "成功通过重定向检测标签: $tag" -ForegroundColor Green
        }
    } catch {
        Write-Warning "通过 HTTP 重定向检测最新版本失败: $_.Exception.Message"
    }
}

# Resolve version numbers
if ($tag -and $tag -match 'open-design-v(.+)') {
    $VERSION = $Matches[1]
} elseif ($tag -and $tag -match 'v(.+)') {
    $VERSION = $Matches[1]
} else {
    $VERSION = "0.11.0"
    $tag = "open-design-v$VERSION"
    Write-Warning "无法检测到最新发布版本，将使用默认推荐版本: $VERSION"
}

# Get dependency versions dynamically using jsDelivr CDN (extremely fast and bypasses raw.githubusercontent limits)
Write-Host "正在解析最新版依存组件版本..."
try {
    # Desktop package.json contains Electron version
    $desktopJsonUrl = "https://cdn.jsdelivr.net/gh/nexu-io/open-design@$tag/apps/desktop/package.json"
    if ($useProxy) {
        $desktopJson = Invoke-RestMethod -Uri $desktopJsonUrl -Proxy "http://127.0.0.1:$proxyPort" -TimeoutSec 10
    } else {
        $desktopJson = Invoke-RestMethod -Uri $desktopJsonUrl -TimeoutSec 10
    }
    $ELECTRON_VERSION = $desktopJson.devDependencies.electron
    
    # Daemon package.json contains better-sqlite3 & node-pty versions
    $daemonJsonUrl = "https://cdn.jsdelivr.net/gh/nexu-io/open-design@$tag/apps/daemon/package.json"
    if ($useProxy) {
        $daemonJson = Invoke-RestMethod -Uri $daemonJsonUrl -Proxy "http://127.0.0.1:$proxyPort" -TimeoutSec 10
    } else {
        $daemonJson = Invoke-RestMethod -Uri $daemonJsonUrl -TimeoutSec 10
    }
    $BETTER_SQLITE3_VERSION = $daemonJson.dependencies.'better-sqlite3'
    $NODE_PTY_VERSION = $daemonJson.dependencies.'node-pty'
    
    Write-Host "解析成功！依赖项版本配置为:" -ForegroundColor Green
    Write-Host "  - Electron: $ELECTRON_VERSION"
    Write-Host "  - better-sqlite3: $BETTER_SQLITE3_VERSION"
    Write-Host "  - node-pty: $NODE_PTY_VERSION"
} catch {
    # Fallback to safe hardcoded versions if remote fetch fails
    $ELECTRON_VERSION = "41.3.0"
    $BETTER_SQLITE3_VERSION = "12.10.0"
    $NODE_PTY_VERSION = "1.1.0"
    Write-Warning "在线解析组件版本失败 ($_.Exception.Message)，将启用硬编码推荐版本:"
    Write-Host "  - Electron: $ELECTRON_VERSION"
    Write-Host "  - better-sqlite3: $BETTER_SQLITE3_VERSION"
    Write-Host "  - node-pty: $NODE_PTY_VERSION"
}

# 4. Construct asset URLs
$x64PortableUrl = "$($gitHubPrefix)https://github.com/nexu-io/open-design/releases/download/$tag/open-design-$VERSION-win-x64-portable.zip"
$x64SetupUrl = "$($gitHubPrefix)https://github.com/nexu-io/open-design/releases/download/$tag/open-design-$VERSION-win-x64-setup.exe"
$electronArm64Url = "$($gitHubPrefix)https://github.com/electron/electron/releases/download/v$ELECTRON_VERSION/electron-v$ELECTRON_VERSION-win32-arm64.zip"
$betterSqliteUrl = "$($gitHubPrefix)https://github.com/WiseLibs/better-sqlite3/releases/download/v$BETTER_SQLITE3_VERSION/better-sqlite3-v$BETTER_SQLITE3_VERSION-electron-v145-win32-arm64.tar.gz"
$nodePtyNpmUrl = "https://registry.npmmirror.com/node-pty/-/node-pty-$NODE_PTY_VERSION.tgz"
$rceditUrl = "$($gitHubPrefix)https://github.com/electron/rcedit/releases/download/v2.0.0/rcedit-x64.exe"
$iconUrl = "https://cdn.jsdelivr.net/gh/nexu-io/open-design@$tag/tools/pack/resources/win/icon.ico"

# Cache paths
$cachedX64Zip = Join-Path $CACHE_DIR "open-design-$VERSION-win-x64-portable.zip"
$cachedX64Setup = Join-Path $CACHE_DIR "open-design-$VERSION-win-x64-setup.exe"
$cachedElectronZip = Join-Path $CACHE_DIR "electron-v$ELECTRON_VERSION-win32-arm64.zip"
$cachedBetterSqliteTgz = Join-Path $CACHE_DIR "better-sqlite3-v$BETTER_SQLITE3_VERSION-electron-v145-win32-arm64.tar.gz"
$cachedPtyTgz = Join-Path $CACHE_DIR "node-pty-$NODE_PTY_VERSION.tgz"
$cachedRceditExe = Join-Path $CACHE_DIR "rcedit-x64.exe"
$cachedIconIco = Join-Path $CACHE_DIR "icon.ico"

# 5. Download Assets
Write-Host "`n--- 正在下载打包所需资源 ---" -ForegroundColor Cyan

$downloadedZip = $true
if (Test-Path $cachedX64Zip) {
    Write-Host "[缓存命中] $cachedX64Zip" -ForegroundColor Gray
} elseif (Test-Path $cachedX64Setup) {
    Write-Host "[缓存命中] $cachedX64Setup" -ForegroundColor Gray
    $downloadedZip = $false
} else {
    try {
        Write-Host "尝试下载 x64 绿色版便携 ZIP 包..." -ForegroundColor Gray
        # 使用 1 次尝试和短超时来判断 ZIP 是否存在，不存在则快速切换到安装包
        Download-File -Url $x64PortableUrl -OutPath $cachedX64Zip -UseProxy $useProxy -ProxyPort $proxyPort -MaxRetries 1 -ConnectTimeout 3
    } catch {
        Write-Warning "下载 x64 绿色版便携 ZIP 失败，将尝试下载 Setup 安装程序并进行本地解包..."
        $downloadedZip = $false
        Download-File -Url $x64SetupUrl -OutPath $cachedX64Setup -UseProxy $useProxy -ProxyPort $proxyPort -MaxRetries 5
    }
}

Download-File -Url $electronArm64Url -OutPath $cachedElectronZip -UseProxy $useProxy -ProxyPort $proxyPort
Download-File -Url $betterSqliteUrl -OutPath $cachedBetterSqliteTgz -UseProxy $useProxy -ProxyPort $proxyPort
Download-File -Url $nodePtyNpmUrl -OutPath $cachedPtyTgz -UseProxy $false -ProxyPort 0 # No proxy needed for npmmirror
Download-File -Url $rceditUrl -OutPath $cachedRceditExe -UseProxy $useProxy -ProxyPort $proxyPort
Download-File -Url $iconUrl -OutPath $cachedIconIco -UseProxy $false -ProxyPort 0 # CDN is fast directly

# 6. Extract Archives
Write-Host "`n--- 正在解压并释放资源 ---" -ForegroundColor Cyan

if (Test-Path $UNPACK_X64_DIR) {
    Remove-Item $UNPACK_X64_DIR -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
}
New-Item -ItemType Directory -Force -Path $UNPACK_X64_DIR | Out-Null

if ($downloadedZip) {
    Extract-Archive -ArchivePath $cachedX64Zip -TargetDir $UNPACK_X64_DIR
} else {
    # We must extract the NSIS setup exe using 7z
    Write-Host "检测到安装程序，正在使用 7z 解包第一层 (Installer)..." -ForegroundColor Gray
    $has7z = Get-Command "7z" -ErrorAction SilentlyContinue
    $path7z = "7z"
    if (!$has7z) {
        $standardPaths = @(
            "C:\Program Files\7-Zip\7z.exe",
            "C:\Program Files\NanaZip\NanaZipC.exe"
        )
        foreach ($p in $standardPaths) {
            if (Test-Path $p) {
                $path7z = $p
                $has7z = $true
                break
            }
        }
    }
    if (!$has7z) {
        throw "本地系统未找到 7z 命令行工具，请先安装 7-Zip 或 NanaZip 并将其加入环境变量 PATH！"
    }
    
    $unpackTmp = Join-Path $WORK_DIR "installer-unpack"
    if (Test-Path $unpackTmp) {
        Remove-Item $unpackTmp -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
    New-Item -ItemType Directory -Force -Path $unpackTmp | Out-Null
    
    $args7z = @("x", "`"$cachedX64Setup`"", "-o`"$unpackTmp`"", "-y")
    $p7z = Start-Process -FilePath $path7z -ArgumentList $args7z -Wait -NoNewWindow -PassThru
    if ($p7z.ExitCode -ne 0) {
        throw "使用 7z 解压安装包失败！退出代码: $($p7z.ExitCode)"
    }
    
    $pluginsDir = Join-Path $unpackTmp "`$PLUGINSDIR"
    $payloadBase = Join-Path $pluginsDir "payload-base.7z"
    $payloadOverlay = Join-Path $pluginsDir "payload-overlay.7z"
    
    if (!(Test-Path $payloadBase) -or !(Test-Path $payloadOverlay)) {
        throw "在解开的安装包中未找到核心载荷文件 payload-base.7z 或 payload-overlay.7z！"
    }
    
    Write-Host "正在使用 7z 解包并合并第二层 (payload-base.7z)..." -ForegroundColor Gray
    $argsBase = @("x", "`"$payloadBase`"", "-o`"$UNPACK_X64_DIR`"", "-y")
    $pBase = Start-Process -FilePath $path7z -ArgumentList $argsBase -Wait -NoNewWindow -PassThru
    if ($pBase.ExitCode -ne 0) {
        throw "使用 7z 解压缩 payload-base.7z 失败！"
    }
    
    Write-Host "正在使用 7z 解包并合并第二层 (payload-overlay.7z)..." -ForegroundColor Gray
    $argsOverlay = @("x", "`"$payloadOverlay`"", "-o`"$UNPACK_X64_DIR`"", "-y")
    $pOverlay = Start-Process -FilePath $path7z -ArgumentList $argsOverlay -Wait -NoNewWindow -PassThru
    if ($pOverlay.ExitCode -ne 0) {
        throw "使用 7z 解压缩 payload-overlay.7z 失败！"
    }
    
    Write-Host "安装包双层解包并合并成功！" -ForegroundColor Green
}

Extract-Archive -ArchivePath $cachedElectronZip -TargetDir $UNPACK_ELECTRON_DIR
Extract-Archive -ArchivePath $cachedBetterSqliteTgz -TargetDir $UNPACK_BETTER_SQLITE3_DIR
Extract-Archive -ArchivePath $cachedPtyTgz -TargetDir $UNPACK_PTY_DIR

# 7. Assemble ARM64 Portable Package
Write-Host "`n--- 正在组装 ARM64 绿色版本包 ---" -ForegroundColor Cyan
if (Test-Path $ASSEMBLED_DIR) {
    Remove-Item $ASSEMBLED_DIR -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
}
New-Item -ItemType Directory -Force -Path $ASSEMBLED_DIR | Out-Null

# Copy Electron ARM64 base files
Write-Host "复制 Electron ARM64 运行时基础文件..."
Copy-Item -Path "$UNPACK_ELECTRON_DIR\*" -Destination $ASSEMBLED_DIR -Recurse -Force
# Remove Electron's default resources folder
$defaultResources = Join-Path $ASSEMBLED_DIR "resources"
if (Test-Path $defaultResources) {
    Remove-Item $defaultResources -Recurse -Force
}

# Copy original app resources from x64 package
Write-Host "注入原程序资源包 (resources)..."
Copy-Item -Path "$UNPACK_X64_DIR\resources" -Destination $ASSEMBLED_DIR -Recurse -Force

# Rename electron.exe -> Open Design.exe
Write-Host "重命名可执行主程序..."
Rename-Item -Path "$ASSEMBLED_DIR\electron.exe" -NewName "Open Design.exe"

# 8. Swap better-sqlite3 with ARM64 native module
Write-Host "替换 better-sqlite3 原生 ARM64 模块..."
$targetBetterSqliteNode = Join-Path $ASSEMBLED_DIR "resources\app\node_modules\better-sqlite3\build\Release\better_sqlite3.node"
$srcBetterSqliteNode = Join-Path $UNPACK_BETTER_SQLITE3_DIR "build\Release\better_sqlite3.node"
if (!(Test-Path $srcBetterSqliteNode)) {
    throw "未找到下载解压的 better_sqlite3.node，路径: $srcBetterSqliteNode"
}
# Ensure destination folder exists (it should, but safety first)
$destSqliteDir = Split-Path $targetBetterSqliteNode -Parent
New-Item -ItemType Directory -Force -Path $destSqliteDir | Out-Null
Copy-Item -Path $srcBetterSqliteNode -Destination $targetBetterSqliteNode -Force

# 9. Set up node-pty win32-arm64 native prebuilds from npm tarball
Write-Host "设置 node-pty 原生 ARM64 依赖模块..."
$ptyTargetDir = Join-Path $ASSEMBLED_DIR "resources\app\node_modules\node-pty\prebuilds\win32-arm64"
$npmPtySrcDir = Join-Path $UNPACK_PTY_DIR "package\prebuilds\win32-arm64"
if (!(Test-Path $npmPtySrcDir)) {
    throw "解压后的 node-pty 依赖包中未找到 prebuilds\win32-arm64"
}
New-Item -ItemType Directory -Force -Path (Split-Path $ptyTargetDir -Parent) | Out-Null
Copy-Item -Path $npmPtySrcDir -Destination $ptyTargetDir -Recurse -Force

# 10. Burn official icon into launcher executable using rcedit
Write-Host "正在向主程序 (Open Design.exe) 烧录官方图标..."
$launcherPath = Join-Path $ASSEMBLED_DIR "Open Design.exe"
if ((Test-Path $launcherPath) -and (Test-Path $cachedRceditExe) -and (Test-Path $cachedIconIco)) {
    $rceditArgs = @("`"$launcherPath`"", "--set-icon", "`"$cachedIconIco`"")
    $rceditProcess = Start-Process -FilePath $cachedRceditExe -ArgumentList $rceditArgs -Wait -NoNewWindow -PassThru
    if ($rceditProcess.ExitCode -eq 0) {
        Write-Host "官方图标烧录成功！" -ForegroundColor Green
    } else {
        Write-Warning "rcedit 图标注入失败，退出代码: $($rceditProcess.ExitCode)。"
    }
} else {
    Write-Warning "缺少 rcedit 执行程序或图标文件，跳过图标烧录。"
}

# 11. Package assembled files into a portable ZIP archive
$OUTPUT_ZIP = Join-Path $TMP_DIR "open-design-$VERSION-win-arm64-portable.zip"
Write-Host "`n正在超高速压缩输出 ZIP 文件到 $OUTPUT_ZIP ..." -ForegroundColor Cyan
if (Test-Path $OUTPUT_ZIP) {
    Remove-Item $OUTPUT_ZIP -Force
}

# Run 7z or native tar.exe to create zip
$zipSuccess = $false
if ($has7z) {
    Write-Host "检测到 7z，正在使用 7z 进行多线程快速压缩..." -ForegroundColor Gray
    $zipArgs = @("a", "-tzip", "-mx3", "`"$OUTPUT_ZIP`"", "*")
    $zipProcess = Start-Process -FilePath $path7z -ArgumentList $zipArgs -WorkingDirectory $ASSEMBLED_DIR -Wait -NoNewWindow -PassThru
    if ($zipProcess.ExitCode -eq 0) {
        $zipSuccess = $true
    }
}

if (!$zipSuccess) {
    Write-Host "未检测到 7z 或压缩失败，正在使用系统自带 tar.exe 进行单线程压缩..." -ForegroundColor Gray
    $tarArgs = @("-acf", "`"$OUTPUT_ZIP`"", "*")
    $zipProcess = Start-Process -FilePath "C:\Windows\System32\tar.exe" -ArgumentList $tarArgs -WorkingDirectory $ASSEMBLED_DIR -Wait -NoNewWindow -PassThru
    if ($zipProcess.ExitCode -eq 0) {
        $zipSuccess = $true
    }
}

if ($zipSuccess) {
    Write-Host "`n===================================================" -ForegroundColor Green
    Write-Host "   Windows ARM64 绿色版便携归档制作完成！" -ForegroundColor Green
    Write-Host "   目标路径: $OUTPUT_ZIP" -ForegroundColor Green
    Write-Host "===================================================" -ForegroundColor Green
} else {
    throw "打包压缩失败！"
}
