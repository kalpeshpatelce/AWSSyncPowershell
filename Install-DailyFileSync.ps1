# =============================================================================
#  Install-DailyFileSync.ps1
#  - Creates C:\ProgramData\DailyFileSync folder
#  - Copies DailyFileSync.ps1 to that location
#  - Creates scheduled task that runs at 5 PM daily, repeats every 30 min
#    until PC shuts down, runs with highest privileges whether logged on or not
#  - Validates the installation
#
#  MUST RUN AS ADMINISTRATOR
# =============================================================================
#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Configuration ---
$installDir = 'C:\ProgramData\DailyFileSync'
$scriptName = 'DailyFileSync.ps1'
$sourceScript = Join-Path $PSScriptRoot $scriptName
$destScript = Join-Path $installDir $scriptName
$taskName = 'DailyFileSync_5PM'
$taskDescription = 'Daily file sync - runs at 5 PM, repeats every 30 min until shutdown. Logs modified files to Google Sheets.'

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DailyFileSync Installer" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
#  STEP 1: Create install directory
# =============================================================================
Write-Host "[1/5] Creating install directory: $installDir" -ForegroundColor Yellow
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Write-Host "      Created: $installDir" -ForegroundColor Green
}
else {
    Write-Host "      Already exists: $installDir" -ForegroundColor Green
}

# =============================================================================
#  STEP 2: Copy script to install directory
# =============================================================================
Write-Host "[2/5] Copying $scriptName to $installDir" -ForegroundColor Yellow
if (-not (Test-Path $sourceScript)) {
    Write-Host "      ERROR: Source script not found: $sourceScript" -ForegroundColor Red
    Write-Host "      Place this installer in the same folder as $scriptName" -ForegroundColor Red
    exit 1
}

Copy-Item -Path $sourceScript -Destination $destScript -Force
Write-Host "      Copied: $destScript" -ForegroundColor Green

# =============================================================================
#  STEP 3: Create log file if not exists
# =============================================================================
Write-Host "[3/5] Creating log file" -ForegroundColor Yellow
$logFile = Join-Path $installDir 'sync_log.txt'
if (-not (Test-Path $logFile)) {
    New-Item -ItemType File -Path $logFile -Force | Out-Null
    Add-Content -Path $logFile -Value "$(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')    INFO    Log file created by installer"
    Write-Host "      Created: $logFile" -ForegroundColor Green
}
else {
    Write-Host "      Already exists: $logFile" -ForegroundColor Green
}

# =============================================================================
#  STEP 3b: Copy AWS credentials to SYSTEM profile (Task Scheduler runs as SYSTEM)
# =============================================================================
Write-Host "[3b/5] Setting up AWS credentials for SYSTEM account" -ForegroundColor Yellow
$userAwsDir = "$env:USERPROFILE\.aws"
$systemAwsDir = 'C:\Windows\System32\config\systemprofile\.aws'

if (Test-Path "$userAwsDir\credentials") {
    if (-not (Test-Path $systemAwsDir)) {
        New-Item -ItemType Directory -Path $systemAwsDir -Force | Out-Null
    }
    Copy-Item -Path "$userAwsDir\credentials" -Destination "$systemAwsDir\credentials" -Force
    Write-Host "      Copied credentials to SYSTEM profile" -ForegroundColor Green
    if (Test-Path "$userAwsDir\config") {
        Copy-Item -Path "$userAwsDir\config" -Destination "$systemAwsDir\config" -Force
        Write-Host "      Copied config to SYSTEM profile" -ForegroundColor Green
    }
}
else {
    Write-Host "      WARN: No AWS credentials found at $userAwsDir" -ForegroundColor Yellow
    Write-Host "      Run 'aws configure' first, then re-run this installer" -ForegroundColor Yellow
}

# =============================================================================
#  STEP 4: Create Scheduled Task
# =============================================================================
Write-Host "[4/5] Creating scheduled task: $taskName" -ForegroundColor Yellow

# Remove existing task if present
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "      Removed existing task" -ForegroundColor Yellow
}

# PowerShell executable (full path for reliability)
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Action: run the script
$action = New-ScheduledTaskAction `
    -Execute $psExe `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$destScript""" `
    -WorkingDirectory $installDir

# Trigger: Daily at 5 PM, repeat every 30 minutes indefinitely (until shutdown)
$trigger = New-ScheduledTaskTrigger -Daily -At '17:00'
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At '17:00' -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration ([TimeSpan]::MaxValue)).Repetition

# Settings: robust - runs on battery, starts if missed, restarts on failure
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 5)

# Principal: Run whether user is logged on or not, highest privileges
$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

# Register the task
Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description $taskDescription `
    -Force | Out-Null

Write-Host "      Task created: $taskName" -ForegroundColor Green
Write-Host "      Schedule: Daily at 5:00 PM, repeat every 30 min" -ForegroundColor Green
Write-Host "      Run as: SYSTEM (highest privileges, logon not required)" -ForegroundColor Green
Write-Host "      Restart on fail: 3 times, 5 min apart" -ForegroundColor Green
Write-Host "      Start if missed: Yes" -ForegroundColor Green

# =============================================================================
#  STEP 5: Validate installation
# =============================================================================
Write-Host "[5/5] Validating installation..." -ForegroundColor Yellow
Write-Host ""

$allGood = $true

# Check 1: Script file exists
if (Test-Path $destScript) {
    Write-Host "      [OK] Script installed at $destScript" -ForegroundColor Green
}
else {
    Write-Host "      [FAIL] Script not found at $destScript" -ForegroundColor Red
    $allGood = $false
}

# Check 2: Log folder writable
$testFile = Join-Path $installDir '_write_test.tmp'
try {
    'test' | Out-File $testFile -Force
    Remove-Item $testFile -Force
    Write-Host "      [OK] Install directory is writable" -ForegroundColor Green
}
catch {
    Write-Host "      [FAIL] Cannot write to $installDir" -ForegroundColor Red
    $allGood = $false
}

# Check 3: Task exists and is ready
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Write-Host "      [OK] Scheduled task registered: $taskName" -ForegroundColor Green
    Write-Host "           State: $($task.State)" -ForegroundColor Cyan
}
else {
    Write-Host "      [FAIL] Scheduled task not found" -ForegroundColor Red
    $allGood = $false
}

# Check 4: Task trigger is correct
if ($task) {
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    $triggers = $task.Triggers
    if ($triggers.Count -gt 0) {
        $t = $triggers[0]
        Write-Host "      [OK] Trigger: Daily at $($t.StartBoundary)" -ForegroundColor Green
        if ($t.Repetition.Interval) {
            Write-Host "      [OK] Repetition: Every $($t.Repetition.Interval)" -ForegroundColor Green
        }
    }
}

# Check 5: PowerShell can parse the installed script
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($destScript, [ref]$null, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -eq 0) {
    Write-Host "      [OK] Script syntax valid (0 parse errors)" -ForegroundColor Green
}
else {
    Write-Host "      [FAIL] Script has $($parseErrors.Count) parse errors" -ForegroundColor Red
    $allGood = $false
}

# Check 6: AWS CLI available
$awsCmd = Get-Command aws -ErrorAction SilentlyContinue
if ($awsCmd) {
    Write-Host "      [OK] AWS CLI found: $($awsCmd.Source)" -ForegroundColor Green
}
else {
    Write-Host "      [WARN] AWS CLI not in PATH (S3 sync will fail)" -ForegroundColor Yellow
}

# Check 7: AWS credentials configured
if (Test-Path "$env:USERPROFILE\.aws\credentials") {
    Write-Host "      [OK] AWS credentials configured" -ForegroundColor Green
}
else {
    Write-Host "      [WARN] AWS credentials not found at ~\.aws\credentials" -ForegroundColor Yellow
}

# --- Summary ---
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
if ($allGood) {
    Write-Host "  INSTALLATION SUCCESSFUL" -ForegroundColor Green
    Write-Host "  Task will run daily at 5:00 PM and repeat every 30 min." -ForegroundColor Green
    Write-Host "  Logs: $installDir\sync_log.txt" -ForegroundColor Cyan
    Write-Host "  Transcripts: $installDir\transcript_*.log" -ForegroundColor Cyan
}
else {
    Write-Host "  INSTALLATION COMPLETED WITH WARNINGS" -ForegroundColor Yellow
    Write-Host "  Please review the [FAIL] items above." -ForegroundColor Yellow
}
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "To test manually:  powershell -File ""$destScript"" -TestSheetConnection" -ForegroundColor White
Write-Host "To run now:        powershell -File ""$destScript""" -ForegroundColor White
Write-Host "To remove task:    Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false" -ForegroundColor White
Write-Host ""
