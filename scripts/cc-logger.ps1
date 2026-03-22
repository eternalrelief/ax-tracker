# cc-logger.ps1 - AX事業部トラッカー（Claude Code用 / Windows PowerShell）
# cc-logger.sh の PowerShell 版

$ErrorActionPreference = "SilentlyContinue"

$LogDir = Join-Path $env:USERPROFILE ".ax-tracker\logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$Date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
$LogFile = Join-Path $LogDir "$Date.jsonl"

$InputJson = $input | Out-String
if ([string]::IsNullOrWhiteSpace($InputJson)) { exit 0 }

try {
    $Data = $InputJson | ConvertFrom-Json
} catch {
    exit 0
}

$SessionId = if ($Data.session_id) { $Data.session_id } else { "" }
$EventName = if ($Data.hook_event_name) { $Data.hook_event_name } else { "" }
$Pmode = if ($Data.permission_mode) { $Data.permission_mode } else { "" }
$Cwd = if ($Data.cwd) { $Data.cwd } else { "" }
$Timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.000Z")

$Project = if ($Cwd) { Split-Path $Cwd -Leaf } else { "unknown" }

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
            uid = $UidHash; mid = $MidHash; pmode = $Pmode; project = $Project
            source = $(if ($Data.source) { $Data.source } else { "" })
            model = $(if ($Data.model) { $Data.model } else { "" })
            cli = "claude"
        }
    }
    "SessionEnd" {
        $Record = @{
            event = "session_end"; ts = $Timestamp; sid = $SessionId
            uid = $UidHash; mid = $MidHash; pmode = $Pmode; project = $Project
            reason = $(if ($Data.reason) { $Data.reason } else { "" })
            cli = "claude"
        }
    }
    "UserPromptSubmit" {
        $PromptLen = if ($Data.prompt) { $Data.prompt.Length } else { 0 }
        $Record = @{
            event = "user_prompt"; ts = $Timestamp; sid = $SessionId
            uid = $UidHash; mid = $MidHash; pmode = $Pmode; project = $Project
            prompt_len = $PromptLen; cli = "claude"
        }
    }
    "PostToolUse" {
        $ToolName = if ($Data.tool_name) { $Data.tool_name } else { "" }
        $Category = switch -Wildcard ($ToolName) {
            "Bash" { "bash" }
            "Edit" { "file_edit" }
            "Write" { "file_edit" }
            "Read" { "file_read" }
            "Glob" { "search" }
            "Grep" { "search" }
            "Agent" { "subagent" }
            "WebFetch" { "web" }
            "WebSearch" { "web" }
            "mcp__*" { "mcp" }
            default { "other" }
        }
        $Record = @{
            event = "tool_use"; ts = $Timestamp; sid = $SessionId
            uid = $UidHash; mid = $MidHash; pmode = $Pmode; project = $Project
            tool = $ToolName; category = $Category; detail = ""
            cli = "claude"
        }
    }
    "PostToolUseFailure" {
        $ToolName = if ($Data.tool_name) { $Data.tool_name } else { "" }
        $ErrorMsg = if ($Data.error) { $Data.error.Substring(0, [Math]::Min(100, $Data.error.Length)) } else { "" }
        $Record = @{
            event = "tool_failure"; ts = $Timestamp; sid = $SessionId
            uid = $UidHash; mid = $MidHash; pmode = $Pmode; project = $Project
            tool = $ToolName; error_head = $ErrorMsg; cli = "claude"
        }
    }
    "SubagentStart" {
        $Record = @{
            event = "subagent_start"; ts = $Timestamp; sid = $SessionId
            uid = $UidHash; mid = $MidHash; pmode = $Pmode; project = $Project
            agent_id = $(if ($Data.agent_id) { $Data.agent_id } else { "" })
            agent_type = $(if ($Data.agent_type) { $Data.agent_type } else { "" })
            cli = "claude"
        }
    }
    "SubagentStop" {
        $Record = @{
            event = "subagent_stop"; ts = $Timestamp; sid = $SessionId
            uid = $UidHash; mid = $MidHash; pmode = $Pmode; project = $Project
            agent_id = $(if ($Data.agent_id) { $Data.agent_id } else { "" })
            agent_type = $(if ($Data.agent_type) { $Data.agent_type } else { "" })
            cli = "claude"
        }
    }
    "PreCompact" {
        $Record = @{
            event = "compaction"; ts = $Timestamp; sid = $SessionId
            uid = $UidHash; mid = $MidHash; pmode = $Pmode; project = $Project
            trigger = $(if ($Data.trigger) { $Data.trigger } else { "" })
            cli = "claude"
        }
    }
    default { exit 0 }
}

if ($Record) {
    $JsonLine = $Record | ConvertTo-Json -Compress
    Add-Content -Path $LogFile -Value $JsonLine -Encoding UTF8
}

exit 0
