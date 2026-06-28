# =============================================================================
#  DailyFileSync.ps1 - ROBUST Task Scheduler Version
#  Finds files created/modified since last sync on \\outside221\D and logs to Google Sheets.
#  Built specifically for reliable Task Scheduler execution.
#
#  RELIABILITY FEATURES:
#    - Forces TLS 1.2 for HTTPS calls
#    - Waits for network availability before proceeding
#    - Uses UNC path fallback (no reliance on mapped drives)
#    - Mutex prevents duplicate instances
#    - Sets working directory explicitly
#    - Transcript logging captures ALL output for debugging
#    - Proper exit codes for Task Scheduler
#    - Auto-retry on failure (3x with 5-min interval)
#    - StartWhenAvailable (runs if missed while asleep)
#
#  USAGE:
#    .\DailyFileSync.ps1                            # Normal daily sync
#    .\DailyFileSync.ps1 -FullSync                  # Full sync to S3
#    .\DailyFileSync.ps1 -RegisterScheduledTask     # Create 5PM daily task
#    .\DailyFileSync.ps1 -UnregisterScheduledTask   # Remove task
#    .\DailyFileSync.ps1 -TestSheetConnection       # Test Google Sheets
# =============================================================================
[CmdletBinding()]
param(
    [switch]$RegisterScheduledTask,
    [switch]$UnregisterScheduledTask,
    [switch]$TestSheetConnection,
    [switch]$FullSync
)

# --- TASK SCHEDULER RELIABILITY FIXES ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# FIX #3: Use StrictMode Version 1 (Latest crashes on uninitialized properties in Task Scheduler)
Set-StrictMode -Version 1
$ErrorActionPreference = 'Continue'

# FIX #1: Use $PSScriptRoot (always correct when run via -File from Task Scheduler)
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    # Fallback for interactive/ISE: use current directory
    $ScriptDir = $PWD.Path
}
if ($ScriptDir -and (Test-Path $ScriptDir -ErrorAction SilentlyContinue)) {
    Set-Location $ScriptDir
}

# =============================================================================
#  CONFIGURATION
# =============================================================================
$Config = @{
    UNCPath           = 'C:\AWSs3Test'
    S3Bucket          = 'helps-emc-backup'
    S3Region          = 'ap-south-1'
    S3Prefix          = ''
    AWSProfile        = 'default'
    GoogleSheetUrl    = 'https://script.google.com/macros/s/AKfycbycDzI-veTWo5y9XpcUayAotnseiCblReSaxfzHw2Wu85bT5CkLY51LPZcIUtIneOLn/exec'
    LogFolder         = 'C:\ProgramData\DailyFileSync'
    LocalLogFile      = 'C:\ProgramData\DailyFileSync\sync_log.txt'
    MaxRetries        = 5
    RetryBaseDelaySec = 10
    HttpTimeoutSec    = 20
    NetworkWaitMaxSec = 120
    NetworkWaitPollSec = 5
    StartupDelaySec   = 15
    TaskName          = 'DailyFileSync_5PM'
    TaskRunTime       = '17:15'
    EsExePath         = 'C:\Program Files\Everything\es.exe'
    # Last sync timestamp file — tracks when we last successfully synced
    # so no files created after 5 PM are ever missed
    LastSyncFile      = 'C:\ProgramData\DailyFileSync\last_sync_time.txt'
}

# =============================================================================
#  SETUP: Log folder, Transcript, Mutex, EventLog source
# =============================================================================
if (-not (Test-Path $Config.LogFolder)) {
    New-Item -ItemType Directory -Path $Config.LogFolder -Force | Out-Null
}

# FIX #7: Register EventLog source once (Write-EventLog fails without it)
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists('DailyFileSync')) {
        New-EventLog -LogName Application -Source 'DailyFileSync' -ErrorAction SilentlyContinue
    }
}
catch { }

# FIX #6: Log transcript failure to EventLog so we know if debugging is broken
$transcriptPath = Join-Path $Config.LogFolder ("transcript_" + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + ".log")
try { Start-Transcript -Path $transcriptPath -Force | Out-Null }
catch {
    try {
        Write-EventLog -LogName Application -Source 'DailyFileSync' -EventId 1001 -EntryType Warning -Message "Transcript failed: $($_.Exception.Message)" -ErrorAction SilentlyContinue
    }
    catch { }
}

$mutexName = 'Global\DailyFileSync_Mutex_7F3A2B'
$script:mutex = $null
try {
    $script:mutex = [System.Threading.Mutex]::new($false, $mutexName)
    if (-not $script:mutex.WaitOne(0)) {
        Write-Host "Another instance is already running. Exiting."
        try { Stop-Transcript } catch { }
        exit 0
    }
}
catch {
    Write-Host "Mutex check failed: $($_.Exception.Message). Continuing anyway."
}

# =============================================================================
#  HELPER FUNCTIONS
# =============================================================================
function Get-Timestamp { return (Get-Date -Format 'dd-MM-yyyy HH:mm:ss') }
function Get-TimestampISO { return (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "$(Get-Timestamp)    $Level    $Message"
    $color = switch ($Level) {
        'ERROR'   { 'Red' }
        'WARN'    { 'Yellow' }
        'OK'      { 'Green' }
        'SUCCESS' { 'Green' }
        default   { 'White' }
    }
    Write-Host $line -ForegroundColor $color
    try {
        Add-Content -Path $Config.LocalLogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch { }
}

function Format-FileSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N1} KB' -f ($Bytes / 1KB) }
    return "$([int]$Bytes) B"
}

# =============================================================================
#  LAST SYNC TRACKING — ensures no files are missed between runs
# =============================================================================
function Get-LastSyncTime {
    # Returns the last successful sync time, or start-of-today if no record
    if (Test-Path $Config.LastSyncFile -ErrorAction SilentlyContinue) {
        try {
            $content = (Get-Content $Config.LastSyncFile -ErrorAction Stop).Trim()
            $lastTime = [datetime]::ParseExact($content, 'yyyy-MM-dd HH:mm:ss', $null)
            Write-Log "Last sync time: $content" -Level 'INFO'
            return $lastTime
        }
        catch {
            Write-Log "Could not parse last sync file, using start of today" -Level 'WARN'
        }
    }
    else {
        Write-Log "No last sync record found (first run). Using start of today." -Level 'INFO'
    }
    # Default: start of today (catches all of today's files on first run)
    return (Get-Date).Date
}

function Save-LastSyncTime {
    # Save current time as last successful sync
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try {
        $now | Out-File -FilePath $Config.LastSyncFile -Force -Encoding UTF8
        Write-Log "Saved last sync time: $now" -Level 'OK'
    }
    catch {
        Write-Log "Failed to save last sync time: $($_.Exception.Message)" -Level 'ERROR'
    }
}

# =============================================================================
#  NETWORK: Wait for connectivity
# =============================================================================
function Wait-ForNetwork {
    Write-Log "Waiting for network readiness..." -Level 'INFO'
    Write-Log "Startup delay: $($Config.StartupDelaySec)s" -Level 'INFO'
    Start-Sleep -Seconds $Config.StartupDelaySec

    $elapsed = 0
    $maxWait = $Config.NetworkWaitMaxSec
    $poll = $Config.NetworkWaitPollSec

    while ($elapsed -lt $maxWait) {
        $uncOK = Test-Path $Config.UNCPath -ErrorAction SilentlyContinue
        $netOK = $false
        try {
            $dns = [System.Net.Dns]::GetHostAddresses('script.google.com')
            if ($dns.Count -gt 0) { $netOK = $true }
        }
        catch { }

        if ($uncOK -and $netOK) {
            Write-Log "Network ready after ${elapsed}s (UNC=OK, Internet=OK)" -Level 'OK'
            return $true
        }

        Write-Log "Waiting... UNC=$(if($uncOK){'OK'}else{'NO'}) Internet=$(if($netOK){'OK'}else{'NO'}) [${elapsed}s/${maxWait}s]" -Level 'WARN'
        Start-Sleep -Seconds $poll
        $elapsed += $poll
    }

    if (Test-Path $Config.UNCPath -ErrorAction SilentlyContinue) {
        Write-Log "Partial network (UNC OK, internet timed out). Proceeding." -Level 'WARN'
        return $true
    }

    Write-Log "Network not ready after ${maxWait}s. Attempting anyway." -Level 'ERROR'
    return $false
}

# =============================================================================
#  NETWORK: Ensure UNC path access with retries
# =============================================================================
function Ensure-NetworkAccess {
    Write-Log "Checking UNC path: $($Config.UNCPath)" -Level 'INFO'

    for ($attempt = 1; $attempt -le $Config.MaxRetries; $attempt++) {
        if (Test-Path $Config.UNCPath -ErrorAction SilentlyContinue) {
            Write-Log "UNC path accessible: $($Config.UNCPath)" -Level 'OK'
            return $Config.UNCPath
        }

        Write-Log "UNC not accessible (attempt $attempt/$($Config.MaxRetries))" -Level 'WARN'
        if ($attempt -lt $Config.MaxRetries) {
            $delay = $Config.RetryBaseDelaySec * $attempt
            Write-Log "Retrying in ${delay}s..." -Level 'WARN'
            Start-Sleep -Seconds $delay
        }
    }

    Write-Log "UNC path $($Config.UNCPath) not accessible after $($Config.MaxRetries) attempts" -Level 'ERROR'
    return $null
}

# =============================================================================
#  GOOGLE SHEETS: Send data with retry
# =============================================================================
function Send-ToGoogleSheet {
    param(
        [string]$Timestamp,
        [string]$Status,
        [string]$TotalSize,
        [int]$FileCount,
        [string]$Message,
        [string]$Details,
        [string]$Errors
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Ensure no blank values - always fill with meaningful data
    if (-not $TotalSize -or $TotalSize -eq '') { $TotalSize = '0 MB' }
    if (-not $Message -or $Message -eq '') { $Message = 'Daily sync failed' }
    if (-not $Details -or $Details -eq '') { $Details = 'Daily sync failed' }
    if (-not $Errors) { $Errors = '' }

    $payload = @{
        timestamp  = $Timestamp
        status     = $Status
        uploadedMB = $TotalSize
        fileCount  = $FileCount
        message    = $Message
        details    = $Details
        errors     = $Errors
        hostname   = $env:COMPUTERNAME
        runBy      = $env:USERNAME
        scriptVer  = 'DailyFileSync_v2.0'
    } | ConvertTo-Json -Depth 5 -Compress

    Write-Log "Sending to Sheets: Status=$Status, Files=$FileCount" -Level 'INFO'

    for ($attempt = 1; $attempt -le $Config.MaxRetries; $attempt++) {
        try {
            $splat = @{
                Uri             = $Config.GoogleSheetUrl
                Method          = 'Post'
                Body            = $payload
                ContentType     = 'application/json; charset=utf-8'
                TimeoutSec      = $Config.HttpTimeoutSec
                UseBasicParsing = $true
                MaximumRedirection = 10
            }
            $response = Invoke-WebRequest @splat

            if ($response.StatusCode -in @(200, 302)) {
                Write-Log "Sheets OK (attempt $attempt, HTTP $($response.StatusCode))" -Level 'OK'
                return $true
            }
            else {
                Write-Log "Sheets unexpected HTTP $($response.StatusCode)" -Level 'WARN'
            }
        }
        catch {
            Write-Log "Sheets error (attempt $attempt): $($_.Exception.Message)" -Level 'ERROR'
        }

        if ($attempt -lt $Config.MaxRetries) {
            $delay = $Config.RetryBaseDelaySec * $attempt
            Write-Log "Sheets retry in ${delay}s..." -Level 'WARN'
            Start-Sleep -Seconds $delay
        }
    }

    Write-Log "FAILED to send to Sheets after $($Config.MaxRetries) attempts" -Level 'ERROR'
    return $false
}

# =============================================================================
#  S3 SYNC FUNCTIONS
# =============================================================================
function Test-AWSCLI {
    $awsCmd = Get-Command aws -ErrorAction SilentlyContinue
    if ($awsCmd) {
        $script:AWSCliPath = $awsCmd.Source
        return $true
    }
    Write-Log "AWS CLI not found in PATH" -Level 'ERROR'
    return $false
}

function Test-AWSCredentials {
    # Just verify aws s3 ls works and bucket is accessible
    try {
        $result = & $script:AWSCliPath s3 ls "s3://$($Config.S3Bucket)/" --region $Config.S3Region 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "AWS S3 bucket accessible: $($Config.S3Bucket)" -Level 'OK'
            return $true
        }
        else {
            Write-Log "AWS S3 bucket not accessible: $($result -join ' ')" -Level 'ERROR'
            return $false
        }
    }
    catch {
        Write-Log "AWS check failed: $($_.Exception.Message)" -Level 'ERROR'
        return $false
    }
}

# Upload today's modified files to S3 (preserves folder structure)
function Upload-FilesToS3 {
    param(
        [array]$Files,
        [string]$SourceRoot,
        [string]$Bucket,
        [string]$Prefix,
        [string]$Region
    )

    Write-Log "Uploading $($Files.Count) files to S3..." -Level 'INFO'

    if (-not (Test-AWSCLI)) { return @{ Success = 0; Failed = 0; Errors = 'AWS CLI not found' } }
    if (-not (Test-AWSCredentials)) { return @{ Success = 0; Failed = 0; Errors = 'AWS credentials not found' } }

    $successCount = 0
    $failedCount = 0
    $errorMessages = @()

    # Normalize source root for path calculation
    $sourceRootNorm = $SourceRoot.TrimEnd('\')

    foreach ($file in $Files) {
        $filePath = if ($file.Path) { $file.Path } elseif ($file.FullName) { $file.FullName } else { continue }

        # Skip if file doesn't exist (may have been deleted since scan)
        if (-not (Test-Path $filePath -ErrorAction SilentlyContinue)) {
            Write-Log "Skip (not found): $filePath" -Level 'WARN'
            $failedCount++
            continue
        }

        # Calculate S3 key preserving folder structure
        $relativePath = $filePath
        if ($filePath.StartsWith($sourceRootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relativePath = $filePath.Substring($sourceRootNorm.Length).TrimStart('\')
        }
        $s3Key = "$Prefix$($relativePath -replace '\\', '/')"

        # Upload single file
        $cpArgs = @('s3', 'cp', $filePath, "s3://$Bucket/$s3Key", '--region', $Region, '--no-progress')
        if ($Config.AWSProfile -ne 'default') { $cpArgs += '--profile', $Config.AWSProfile }

        try {
            $result = & $script:AWSCliPath $cpArgs 2>&1
            if ($LASTEXITCODE -eq 0) {
                $successCount++
                Write-Log "Uploaded: $($file.Name) -> s3://$Bucket/$s3Key" -Level 'OK'
            }
            else {
                $failedCount++
                $errText = "$($file.Name): $($result -join ' ')"
                $errorMessages += $errText
                Write-Log "S3 upload FAILED: $errText" -Level 'ERROR'
            }
        }
        catch {
            $failedCount++
            $errText = "$($file.Name): $($_.Exception.Message)"
            $errorMessages += $errText
            Write-Log "S3 upload exception: $errText" -Level 'ERROR'
        }

        # Log progress every 20 files
        if (($successCount + $failedCount) % 20 -eq 0) {
            Write-Log "S3 progress: $successCount uploaded, $failedCount failed / $($Files.Count) total" -Level 'INFO'
        }
    }

    Write-Log "S3 upload done: $successCount success, $failedCount failed out of $($Files.Count)" -Level $(if ($failedCount -eq 0) { 'OK' } else { 'WARN' })

    return @{
        Success = $successCount
        Failed  = $failedCount
        Errors  = ($errorMessages | Select-Object -First 3) -join '; '
    }
}

function Sync-ToS3 {
    param([string]$SourcePath, [string]$Bucket, [string]$Prefix, [string]$Region)

    Write-Log "S3 Sync: $SourcePath -> s3://$Bucket/$Prefix" -Level 'INFO'

    if (-not (Test-AWSCLI)) { return $false }
    if (-not (Test-AWSCredentials)) { return $false }

    $syncArgs = @('s3', 'sync', $SourcePath, "s3://$Bucket/$Prefix", '--region', $Region, '--delete', '--no-progress')
    if ($Config.AWSProfile -ne 'default') { $syncArgs += '--profile', $Config.AWSProfile }

    $startTime = Get-Date
    $syncLog = Join-Path $Config.LogFolder ("s3_sync_" + (Get-TimestampISO) + ".log")
    $syncErrLog = $syncLog + ".error"

    try {
        $proc = Start-Process -FilePath $script:AWSCliPath -ArgumentList $syncArgs -Wait -NoNewWindow -PassThru -RedirectStandardOutput $syncLog -RedirectStandardError $syncErrLog
        $duration = (Get-Date) - $startTime

        if ($proc.ExitCode -eq 0) {
            Write-Log "S3 sync SUCCESS in $($duration.ToString('hh\:mm\:ss'))" -Level 'SUCCESS'
            Send-ToGoogleSheet -Timestamp (Get-Timestamp) -Status 'COMPLETED' -TotalSize '0 MB' -FileCount 0 -Message "S3 sync completed in $($duration.ToString('hh\:mm\:ss'))" -Details '' -Errors ''
            return $true
        }
        else {
            $errMsg = if (Test-Path $syncErrLog) { (Get-Content $syncErrLog -Tail 5) -join '; ' } else { "Exit $($proc.ExitCode)" }
            Write-Log "S3 sync FAILED: $errMsg" -Level 'ERROR'
            Send-ToGoogleSheet -Timestamp (Get-Timestamp) -Status 'ERROR' -TotalSize '0 MB' -FileCount 0 -Message "S3 sync failed - Exit code $($proc.ExitCode)" -Details $errMsg -Errors $errMsg
            return $false
        }
    }
    catch {
        Write-Log "S3 exception: $($_.Exception.Message)" -Level 'ERROR'
        Send-ToGoogleSheet -Timestamp (Get-Timestamp) -Status 'ERROR' -TotalSize '0 MB' -FileCount 0 -Message 'S3 sync failed - Exception' -Details $_.Exception.Message -Errors $_.Exception.Message
        return $false
    }
}

# =============================================================================
#  DAILY FILE SYNC - Main logic
# =============================================================================
function Invoke-DailyFileSync {
    Write-Log "========== DAILY FILE SYNC STARTED ==========" -Level 'OK'
    Write-Log "Computer: $env:COMPUTERNAME | User: $env:USERNAME | Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level 'INFO'

    # --- IMMEDIATELY send STARTED to Google Sheets ---
    Send-ToGoogleSheet -Timestamp (Get-Timestamp) -Status 'STARTED' -TotalSize '0 MB' -FileCount 0 -Message "Daily sync initiated (today's files)" -Details 'initiated' -Errors ''

    # Step 1: Wait for network
    $null = Wait-ForNetwork

    # Step 2: Get accessible source path
    $sourcePath = Ensure-NetworkAccess
    if (-not $sourcePath) {
        $errorMsg = "Cannot access $($Config.UNCPath)"
        Write-Log $errorMsg -Level 'ERROR'
        Send-ToGoogleSheet -Timestamp (Get-Timestamp) -Status 'ERROR' -TotalSize '0 MB' -FileCount 0 -Message 'Daily sync failed - Network failed' -Details $errorMsg -Errors $errorMsg
        return $false
    }
    Write-Log "Source: $sourcePath" -Level 'OK'

    # Step 3: Find files modified SINCE LAST SYNC (not just "today")
    # This ensures files created after 5 PM are caught on the next run
    $sinceTime = Get-LastSyncTime
    Write-Log "Finding files modified since: $(Get-Date $sinceTime -Format 'yyyy-MM-dd HH:mm:ss')" -Level 'INFO'
    $files = @()
    $method = 'GetChildItem'

    try {
        $esRunning = Get-Process -Name 'Everything' -ErrorAction SilentlyContinue
        if ((Test-Path $Config.EsExePath) -and $esRunning) {
            Write-Log "Using Everything search..." -Level 'INFO'
            $method = 'Everything'
            # FIX #8: Correct es.exe syntax for today's files
            $todayStr = Get-Date -Format 'yyyy-MM-dd'
            $esArgs = @("dm:$todayStr", "path:$sourcePath")
            $esOut = & $Config.EsExePath $esArgs 2>$null
            if ($LASTEXITCODE -eq 0 -and $esOut) {
                foreach ($line in $esOut) {
                    if ($line -and (Test-Path $line -ErrorAction SilentlyContinue)) {
                        try {
                            $fileItem = Get-Item $line -ErrorAction SilentlyContinue
                            if ($fileItem -and (-not $fileItem.PSIsContainer) -and ($fileItem.LastWriteTime -ge $sinceTime)) {
                                $files += [PSCustomObject]@{
                                    Path = $fileItem.FullName
                                    Name = $fileItem.Name
                                    Length = $fileItem.Length
                                    Size = ''
                                }
                            }
                        }
                        catch { }
                    }
                }
                Write-Log "Everything: $($files.Count) files since last sync" -Level 'OK'
            }
            else {
                Write-Log "Everything returned nothing, falling back" -Level 'WARN'
                $method = 'GetChildItem'
            }
        }

        if ($method -eq 'GetChildItem') {
            Write-Log "Using Get-ChildItem scan..." -Level 'INFO'
            $files = @(Get-ChildItem -Path $sourcePath -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $sinceTime })
            Write-Log "GetChildItem: $($files.Count) files since last sync" -Level 'OK'
        }
    }
    catch {
        $errorMsg = "Search error: $($_.Exception.Message)"
        Write-Log $errorMsg -Level 'ERROR'
        Send-ToGoogleSheet -Timestamp (Get-Timestamp) -Status 'ERROR' -TotalSize '0 MB' -FileCount 0 -Message "Daily sync failed - File search failed ($method)" -Details $errorMsg -Errors $errorMsg
        return $false
    }

    # Step 4: Calculate stats
    $fileCount = $files.Count
    $totalSize = 0
    if ($fileCount -gt 0) {
        $m = $files | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue
        # FIX #4: $m.Sum can be $null under StrictMode - always default to 0
        $totalSize = if ($m -and $m.Sum) { [double]$m.Sum } else { 0 }
    }
    $totalSizeMB = '{0:N2} MB' -f ($totalSize / 1MB)

    # Step 5: Build file list with FULL PATH and modified/created status
    $details = 'No new files since last sync'
    if ($fileCount -gt 0) {
        $fileEntries = @()
        $maxEntries = 20  # Show up to 20 files in detail, rest as count
        $shownFiles = $files | Select-Object -First $maxEntries
        foreach ($f in $shownFiles) {
            $fPath = if ($f.Path) { $f.Path } elseif ($f.FullName) { $f.FullName } else { $f.Name }
            # Determine if file was created or modified
            $fStatus = 'modified'
            try {
                $fItem = if ($f.CreationTime) { $f } else { Get-Item $fPath -ErrorAction SilentlyContinue }
                if ($fItem -and $fItem.CreationTime -ge $sinceTime) {
                    $fStatus = 'created'
                }
            }
            catch { }
            $fileEntries += "$fPath $fStatus"
        }
        $details = $fileEntries -join '; '
        if ($fileCount -gt $maxEntries) {
            $details += " ... (+$($fileCount - $maxEntries) more)"
        }
    }

    # Step 6: Upload files to S3
    $s3Result = $null
    if ($fileCount -gt 0) {
        Write-Log "Uploading $fileCount files to S3 bucket: $($Config.S3Bucket)" -Level 'INFO'
        $s3Result = Upload-FilesToS3 -Files $files -SourceRoot $sourcePath -Bucket $Config.S3Bucket -Prefix $Config.S3Prefix -Region $Config.S3Region

        if ($s3Result.Failed -eq 0 -and $s3Result.Success -gt 0) {
            # All files uploaded — save sync time so next run picks up from here
            Save-LastSyncTime
            $completedMsg = "Daily sync completed - $fileCount file(s) uploaded $totalSizeMB to S3"
            Write-Log $completedMsg -Level 'OK'
            $sheetOK = Send-ToGoogleSheet -Timestamp (Get-Timestamp) -Status 'COMPLETED' -TotalSize $totalSizeMB -FileCount $fileCount -Message $completedMsg -Details $details -Errors ''
        }
        elseif ($s3Result.Success -gt 0 -and $s3Result.Failed -gt 0) {
            # Partial success — DO NOT update last sync time (retry failed files next run)
            $partialMsg = "Daily sync partial - $($s3Result.Success) uploaded, $($s3Result.Failed) failed, $totalSizeMB"
            Write-Log $partialMsg -Level 'WARN'
            $sheetOK = Send-ToGoogleSheet -Timestamp (Get-Timestamp) -Status 'COMPLETED' -TotalSize $totalSizeMB -FileCount $s3Result.Success -Message $partialMsg -Details $details -Errors $s3Result.Errors
        }
        else {
            # All failed — DO NOT update last sync time (retry everything next run)
            $failMsg = "Daily sync failed - S3 upload failed for all $fileCount files"
            Write-Log $failMsg -Level 'ERROR'
            $sheetOK = Send-ToGoogleSheet -Timestamp (Get-Timestamp) -Status 'ERROR' -TotalSize $totalSizeMB -FileCount 0 -Message $failMsg -Details $details -Errors $s3Result.Errors
        }
    }
    else {
        # No new files — update sync time anyway so we don't re-scan old range
        Save-LastSyncTime
        Write-Log "No new files since last sync" -Level 'OK'
        $sheetOK = Send-ToGoogleSheet -Timestamp (Get-Timestamp) -Status 'COMPLETED' -TotalSize '0 MB' -FileCount 0 -Message 'Daily sync completed - No new files since last sync' -Details 'No new files' -Errors ''
    }

    Write-Log "========== DAILY FILE SYNC COMPLETED ==========" -Level 'OK'
    return $sheetOK
}

# =============================================================================
#  FULL S3 SYNC
# =============================================================================
function Invoke-FullS3Sync {
    Write-Log "========== FULL S3 SYNC ==========" -Level 'OK'

    # Send STARTED immediately
    Send-ToGoogleSheet -Timestamp (Get-Timestamp) -Status 'STARTED' -TotalSize '0 MB' -FileCount 0 -Message 'S3 full sync initiated' -Details 'initiated' -Errors ''

    $null = Wait-ForNetwork
    $sourcePath = Ensure-NetworkAccess
    if (-not $sourcePath) {
        $errorMsg = "Source not accessible for S3 sync"
        Write-Log $errorMsg -Level 'ERROR'
        Send-ToGoogleSheet -Timestamp (Get-Timestamp) -Status 'ERROR' -TotalSize '0 MB' -FileCount 0 -Message 'S3 sync failed - Network access failed' -Details $errorMsg -Errors $errorMsg
        return $false
    }
    return (Sync-ToS3 -SourcePath $sourcePath -Bucket $Config.S3Bucket -Prefix $Config.S3Prefix -Region $Config.S3Region)
}

# =============================================================================
#  TASK SCHEDULER REGISTRATION - Bulletproof settings
# =============================================================================
function Register-DailySyncTask {
    $taskName = $Config.TaskName
    # FIX #2: $PSCommandPath can be null in Task Scheduler - use multiple fallbacks
    $scriptPath = if ($PSCommandPath) { $PSCommandPath }
                  elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path }
                  else { Join-Path $ScriptDir 'DailyFileSync.ps1' }

    Write-Log "Registering Task: $taskName" -Level 'INFO'
    Write-Log "Script: $scriptPath" -Level 'INFO'

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argStr = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$scriptPath"""
    $workDir = Split-Path $scriptPath -Parent

    $action = New-ScheduledTaskAction -Execute $psExe -Argument $argStr -WorkingDirectory $workDir
    $trigger = New-ScheduledTaskTrigger -Daily -At $Config.TaskRunTime

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)

    # FIX #11: Use SYSTEM + ServiceAccount (most reliable, no password needed, runs without logon)
    # Note: SYSTEM cannot access mapped drives - but script uses UNC path as primary strategy
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Daily file sync - robust version with network wait and retry" -Force
        Write-Log "Task '$taskName' registered!" -Level 'SUCCESS'
        Write-Log "StartWhenAvailable=Yes, RestartOnFail=3x, Battery=OK" -Level 'INFO'
    }
    catch {
        Write-Log "Failed to register task: $($_.Exception.Message)" -Level 'ERROR'
        Write-Log "Try running as Administrator" -Level 'WARN'
    }
}

function Unregister-DailySyncTask {
    $taskName = $Config.TaskName
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Log "Task '$taskName' removed" -Level 'OK'
    }
    else {
        Write-Log "Task '$taskName' not found" -Level 'WARN'
    }
}

# =============================================================================
#  TEST CONNECTION
# =============================================================================
function Test-SheetConnection {
    Write-Log "Testing Google Sheets..." -Level 'INFO'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $body = @{ test = 'connection'; timestamp = (Get-Timestamp); host = $env:COMPUTERNAME } | ConvertTo-Json
    try {
        $r = Invoke-WebRequest -Uri $Config.GoogleSheetUrl -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 15 -UseBasicParsing -MaximumRedirection 10
        Write-Log "Sheets connection OK! HTTP $($r.StatusCode)" -Level 'SUCCESS'
    }
    catch {
        Write-Log "Sheets FAILED: $($_.Exception.Message)" -Level 'ERROR'
    }
}

# =============================================================================
#  ENTRY POINT - with exit codes for Task Scheduler
# =============================================================================
$exitCode = 0
try {
    if ($RegisterScheduledTask) {
        Register-DailySyncTask
    }
    elseif ($UnregisterScheduledTask) {
        Unregister-DailySyncTask
    }
    elseif ($TestSheetConnection) {
        Test-SheetConnection
    }
    elseif ($FullSync) {
        $result = Invoke-FullS3Sync
        if (-not $result) { $exitCode = 1 }
    }
    else {
        $result = Invoke-DailyFileSync
        if (-not $result) { $exitCode = 1 }
    }
}
catch {
    Write-Log "UNHANDLED EXCEPTION: $($_.Exception.Message)" -Level 'ERROR'
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level 'ERROR'
    $exitCode = 2
}
finally {
    if ($script:mutex) {
        try { $script:mutex.ReleaseMutex() }
        catch { }
        try { $script:mutex.Dispose() }
        catch { }
    }
    try { Stop-Transcript }
    catch { }
}

exit $exitCode
