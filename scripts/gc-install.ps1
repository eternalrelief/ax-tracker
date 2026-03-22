# gc-install.ps1 - AX事業部トラッカー インストーラー（Windows版）
# PowerShell 5.1+ 対応
#
# 使い方:
#   irm https://raw.githubusercontent.com/eternalrelief/ax-tracker/main/scripts/gc-install.ps1 | iex
#   または: .\gc-install.ps1

$ErrorActionPreference = "Stop"

$TrackerDir = Join-Path $env:USERPROFILE ".ax-tracker"
$ScriptsDir = Join-Path $TrackerDir "scripts"
$LogsDir = Join-Path $TrackerDir "logs"
$WorklogsDir = Join-Path $TrackerDir "worklogs"

Write-Host "=== デジタルゴリラ AX事業部トラッカー セットアップ (Windows) ===" -ForegroundColor Cyan
Write-Host ""

# 1. ディレクトリ作成
foreach ($dir in @($ScriptsDir, $LogsDir, $WorklogsDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}
Write-Host "[OK] ディレクトリ作成: $TrackerDir" -ForegroundColor Green

# 2. スクリプトコピー
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Scripts = @("gc-logger.ps1", "cc-logger.ps1", "gc-logger.sh", "cc-logger.sh", "worklog-draft.sh")
foreach ($script in $Scripts) {
    $src = Join-Path $ScriptDir $script
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $ScriptsDir $script) -Force
        Write-Host "[OK] $script インストール" -ForegroundColor Green
    }
}

# 3. ユーザープロファイル生成
$ProfilePath = Join-Path $TrackerDir "user-profile.json"
if (-not (Test-Path $ProfilePath)) {
    $GitName = & git config user.name 2>$null
    if (-not $GitName) { $GitName = "Unknown" }
    $GitEmail = & git config user.email 2>$null
    if (-not $GitEmail) { $GitEmail = "unknown@example.com" }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $UidHash = -join ($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($GitEmail)) | ForEach-Object { $_.ToString("x2") })[0..7]
    $MidHash = -join ($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($env:COMPUTERNAME)) | ForEach-Object { $_.ToString("x2") })[0..7]

    $Profile = @{
        uid = $UidHash
        mid = $MidHash
        git_name = $GitName
        git_email = $GitEmail
        hostname = $env:COMPUTERNAME
        os = "windows"
        registered_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.000Z")
    } | ConvertTo-Json
    Set-Content -Path $ProfilePath -Value $Profile -Encoding UTF8

    Write-Host "[OK] ユーザープロファイル生成: UID=$UidHash / Name=$GitName" -ForegroundColor Green
} else {
    $existingUid = (Get-Content $ProfilePath | ConvertFrom-Json).uid
    Write-Host "[OK] ユーザープロファイル既存: $existingUid" -ForegroundColor Green
}

# 4. Gemini CLI hooks 設定
$GeminiSettings = Join-Path $env:USERPROFILE ".gemini\settings.json"
$GeminiDir = Split-Path $GeminiSettings -Parent
if (-not (Test-Path $GeminiDir)) { New-Item -ItemType Directory -Path $GeminiDir -Force | Out-Null }

$LoggerPath = (Join-Path $ScriptsDir "gc-logger.ps1") -replace '\\', '/'
$GeminiHooks = @{
    hooks = @{
        SessionStart = @(@{ hooks = @(@{ name = "ax-tracker-session-start"; type = "command"; command = "powershell -ExecutionPolicy Bypass -File `"$LoggerPath`"" }) })
        SessionEnd = @(@{ hooks = @(@{ name = "ax-tracker-session-end"; type = "command"; command = "powershell -ExecutionPolicy Bypass -File `"$LoggerPath`"" }) })
        BeforeAgent = @(@{ hooks = @(@{ name = "ax-tracker-prompt"; type = "command"; command = "powershell -ExecutionPolicy Bypass -File `"$LoggerPath`"" }) })
        AfterAgent = @(@{ hooks = @(@{ name = "ax-tracker-response"; type = "command"; command = "powershell -ExecutionPolicy Bypass -File `"$LoggerPath`"" }) })
        AfterTool = @(@{ matcher = "*"; hooks = @(@{ name = "ax-tracker-tool"; type = "command"; command = "powershell -ExecutionPolicy Bypass -File `"$LoggerPath`"" }) })
        PreCompress = @(@{ hooks = @(@{ name = "ax-tracker-compress"; type = "command"; command = "powershell -ExecutionPolicy Bypass -File `"$LoggerPath`"" }) })
    }
}

if (Test-Path $GeminiSettings) {
    $existing = Get-Content $GeminiSettings -Raw | ConvertFrom-Json
    $existing | Add-Member -NotePropertyName "hooks" -NotePropertyValue $GeminiHooks.hooks -Force
    $existing | ConvertTo-Json -Depth 10 | Set-Content $GeminiSettings -Encoding UTF8
    Write-Host "[OK] Gemini CLI settings.json にhooksを追加（マージ）" -ForegroundColor Green
} else {
    $GeminiHooks | ConvertTo-Json -Depth 10 | Set-Content $GeminiSettings -Encoding UTF8
    Write-Host "[OK] Gemini CLI settings.json を新規作成" -ForegroundColor Green
}

# 5. Claude Code hooks 設定
$ClaudeSettings = Join-Path $env:USERPROFILE ".claude\settings.json"
$ClaudeDir = Split-Path $ClaudeSettings -Parent
if (-not (Test-Path $ClaudeDir)) { New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null }

$CcLoggerPath = (Join-Path $ScriptsDir "cc-logger.ps1") -replace '\\', '/'
$ClaudeHooks = @{
    SessionStart = @(@{ hooks = @(@{ type = "command"; command = "powershell -ExecutionPolicy Bypass -File `"$CcLoggerPath`"" }) })
    SessionEnd = @(@{ hooks = @(@{ type = "command"; command = "powershell -ExecutionPolicy Bypass -File `"$CcLoggerPath`"" }) })
    UserPromptSubmit = @(@{ hooks = @(@{ type = "command"; command = "powershell -ExecutionPolicy Bypass -File `"$CcLoggerPath`"" }) })
    PostToolUse = @(@{ hooks = @(@{ type = "command"; command = "powershell -ExecutionPolicy Bypass -File `"$CcLoggerPath`"" }) })
    PostToolUseFailure = @(@{ hooks = @(@{ type = "command"; command = "powershell -ExecutionPolicy Bypass -File `"$CcLoggerPath`"" }) })
    SubagentStart = @(@{ hooks = @(@{ type = "command"; command = "powershell -ExecutionPolicy Bypass -File `"$CcLoggerPath`"" }) })
    SubagentStop = @(@{ hooks = @(@{ type = "command"; command = "powershell -ExecutionPolicy Bypass -File `"$CcLoggerPath`"" }) })
    PreCompact = @(@{ hooks = @(@{ type = "command"; command = "powershell -ExecutionPolicy Bypass -File `"$CcLoggerPath`"" }) })
}

if (Test-Path $ClaudeSettings) {
    $existing = Get-Content $ClaudeSettings -Raw | ConvertFrom-Json
    if (-not $existing.hooks) {
        $existing | Add-Member -NotePropertyName "hooks" -NotePropertyValue @{} -Force
    }
    foreach ($key in $ClaudeHooks.Keys) {
        $existing.hooks | Add-Member -NotePropertyName $key -NotePropertyValue $ClaudeHooks[$key] -Force
    }
    $existing | ConvertTo-Json -Depth 10 | Set-Content $ClaudeSettings -Encoding UTF8
    Write-Host "[OK] Claude Code settings.json にhooksを追加（マージ）" -ForegroundColor Green
} else {
    @{ hooks = $ClaudeHooks } | ConvertTo-Json -Depth 10 | Set-Content $ClaudeSettings -Encoding UTF8
    Write-Host "[OK] Claude Code settings.json を新規作成" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== セットアップ完了 ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  ログ保存先: $LogsDir\YYYY-MM-DD.jsonl" -ForegroundColor Yellow
Write-Host "  Gemini CLI / Claude Code どちらを使っても自動でログが記録されます" -ForegroundColor Yellow
Write-Host ""
