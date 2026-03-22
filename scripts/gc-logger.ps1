# gc-logger.ps1 - AX事業部トラッカー（Gemini CLI用 / Windows PowerShell）
# gc-logger.sh の PowerShell 版

$ErrorActionPreference = "SilentlyContinue"

$LogDir = Join-Path $env:USERPROFILE ".ax-tracker\logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$Date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
$LogFile = Join-Path $LogDir "$Date.jsonl"

# stdin から JSON 読み込み
$InputJson = $input | Out-String
if ([string]::IsNullOrWhiteSpace($InputJson)) {
    Write-Output '{"decision":"allow"}'
    exit 0
}

try {
    $Data = $InputJson | ConvertFrom-Json
} catch {
    Write-Output '{"decision":"allow"}'
    exit 0
}

$SessionId = if ($Data.session_id) { $Data.session_id } else { "" }
$EventName = if ($Data.hook_event_name) { $Data.hook_event_name } else { "" }
$Cwd = if ($Data.cwd) { $Data.cwd } else { "" }
$Timestamp = if ($Data.timestamp) { $Data.timestamp } else { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.000Z") }

$Project = if ($Cwd) { Split-Path $Cwd -Leaf } else { "unknown" }

# ユーザーID
$ProfilePath = Join-Path $env:USERPROFILE ".ax-tracker\user-profile.json"
if (Test-Path $ProfilePath) {
    $Profile = Get-Content $ProfilePath | ConvertFrom-Json
    $UidHash = $Profile.uid
    $MidHash = $Profile.mid
} else {
    $GitEmail = & git config user.email 2>$null
    if (-not $GitEmail) { $GitEmail = "unknown" }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $UidHash = -join ($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($GitEmail)) | ForEach-Object { $_.ToString("x2") })[0..7]
    $MidHash = -join ($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($env:COMPUTERNAME)) | ForEach-Object { $_.ToString("x2") })[0..7]
}

$Record = $null

switch ($EventName) {
    "SessionStart" {
        $Record = @{
            event = "session_start"; ts = $Timestamp; sid = $SessionId
            uid = $UidHash; mid = $MidHash; project = $Project
            source = $(if ($Data.source) { $Data.source } else { "" })
            cli = "gemini"
        }
    }
    "SessionEnd" {
        $Record = @{
            event = "session_end"; ts = $Timestamp; sid = $SessionId
            uid = $UidHash; mid = $MidHash; project = $Project
            reason = $(if ($Data.reason) { $Data.reason } else { "" })
            cli = "gemini"
        }
    }
    "BeforeAgent" {
        $PromptLen = if ($Data.prompt) { $Data.prompt.Length } else { 0 }
        $Record = @{
            event = "user_prompt"; ts = $Timestamp; sid = $SessionId
            uid = $UidHash; mid = $MidHash; project = $Project
            prompt_len = $PromptLen; cli = "gemini"
        }
    }
    "AfterAgent" {
        $Record = @{
            event = "agent_response"; ts = $Timestamp; sid = $SessionId
            uid = $UidHash; mid = $MidHash; project = $Project
            cli = "gemini"
        }
    }
    "AfterTool" {
        $ToolName = if ($Data.tool_name) { $Data.tool_name } else { "" }
        $Category = switch -Wildcard ($ToolName) {
            "run_shell_command" { "bash" }
            "shell" { "bash" }
            "edit_file" { "file_edit" }
            "write_file" { "file_edit" }
            "create_file" { "file_edit" }
            "read_file" { "file_read" }
            "read_many_files" { "file_read" }
            "glob" { "search" }
            "grep" { "search" }
            "find_files" { "search" }
            "list_directory" { "search" }
            "web_search" { "web" }
            "web_fetch" { "web" }
            "mcp__*" { "mcp" }
            default { "other" }
        }

        $HasError = $Data.tool_response.error
        if ($HasError) {
            $Record = @{
                event = "tool_failure"; ts = $Timestamp; sid = $SessionId
                uid = $UidHash; mid = $MidHash; project = $Project
                tool = $ToolName; category = $Category
                error_head = $HasError.Substring(0, [Math]::Min(100, $HasError.Length))
                cli = "gemini"
            }
        } else {
            $Record = @{
                event = "tool_use"; ts = $Timestamp; sid = $SessionId
                uid = $UidHash; mid = $MidHash; project = $Project
                tool = $ToolName; category = $Category; detail = ""
                cli = "gemini"
            }
        }
    }
    "PreCompress" {
        $Record = @{
            event = "compaction"; ts = $Timestamp; sid = $SessionId
            uid = $UidHash; mid = $MidHash; project = $Project
            trigger = $(if ($Data.trigger) { $Data.trigger } else { "" })
            cli = "gemini"
        }
    }
    default {
        Write-Output '{"decision":"allow"}'
        exit 0
    }
}

if ($Record) {
    $JsonLine = $Record | ConvertTo-Json -Compress
    Add-Content -Path $LogFile -Value $JsonLine -Encoding UTF8
}

# Gemini CLI にはallowを返す
Write-Output '{"decision":"allow"}'
exit 0
