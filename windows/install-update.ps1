param([Parameter(Mandatory = $true)][string]$Transaction)
$ErrorActionPreference = 'Stop'

# All replacement and cleanup paths are derived from this one sibling directory.
$transactionRoot = [IO.Path]::GetFullPath($Transaction).TrimEnd('\')
$config = Get-Content -LiteralPath (Join-Path $transactionRoot 'config.json') -Raw | ConvertFrom-Json
$target = [IO.Path]::GetFullPath($config.target).TrimEnd('\')
$expected = Join-Path (Split-Path -Parent $target) ('.' + (Split-Path -Leaf $target) + '.yecatz-update')
if ($transactionRoot -ne $expected -or $target -eq [IO.Path]::GetPathRoot($target).TrimEnd('\')) {
    throw 'Invalid update directory.'
}
if ((Get-Item -LiteralPath $transactionRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'Update directory must not be a link.'
}
$incoming = Join-Path $transactionRoot 'Yecatz'
$backup = Join-Path $transactionRoot 'previous'
$ready = Join-Path $transactionRoot 'ready.json'
$newProcess = $null
$movedOld = $false
$installed = $false
$healthy = $false

function Move-WithRetry([string]$Source, [string]$Destination) {
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq 29) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Start-Yecatz([string]$UpdateError = '') {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $target 'Yecatz.exe'
    $startInfo.WorkingDirectory = $target
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    if ($UpdateError) { $startInfo.EnvironmentVariables['YECATZ_UPDATE_ERROR'] = $UpdateError }
    return [System.Diagnostics.Process]::Start($startInfo)
}

function Remove-WithRetry([string]$Path) {
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
            return
        } catch {
            if ($attempt -eq 29) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

try {
    if (-not (Test-Path -LiteralPath (Join-Path $incoming 'Yecatz.exe')) -or
        (Test-Path -LiteralPath $backup)) { throw 'Invalid or unfinished update.' }
    $oldProcess = Get-Process -Id $config.parent_pid -ErrorAction SilentlyContinue
    if ($oldProcess -and $oldProcess.Path -ne (Join-Path $target 'Yecatz.exe')) {
        throw 'The running application path does not match the installation.'
    }
    [IO.File]::WriteAllText((Join-Path $transactionRoot 'helper-ready'), 'ready')
    if ($oldProcess -and -not $oldProcess.WaitForExit(60000)) {
        throw 'Yecatz did not exit within 60 seconds.'
    }
    Move-WithRetry $target $backup
    $movedOld = $true
    Move-WithRetry $incoming $target
    $installed = $true
    [IO.File]::WriteAllText((Join-Path $transactionRoot 'installed'), 'installed')
    # Reset PyInstaller's inherited state before starting the replacement build.
    $env:PYINSTALLER_RESET_ENVIRONMENT = '1'
    $newProcess = Start-Yecatz
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        if (Test-Path -LiteralPath $ready) {
            $ack = Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json
            if ($ack.token -eq $config.token -and $ack.tag -eq $config.tag -and $ack.pid -eq $newProcess.Id) {
                Start-Sleep -Seconds 2
                $newProcess.Refresh()
                $healthy = -not $newProcess.HasExited
                break
            }
        }
        $newProcess.Refresh()
        if ($newProcess.HasExited) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $healthy) { throw 'The new version did not confirm a successful startup.' }
    # The exact old installation is removed only after the replacement is ready.
    Remove-WithRetry $backup
    Remove-WithRetry $transactionRoot
} catch {
    $failure = $_.Exception.Message
    if ($healthy) {
        # A partial directory cleanup may have removed config.json before a locked file.
        [IO.Directory]::CreateDirectory($transactionRoot) | Out-Null
        [IO.File]::WriteAllText((Join-Path $transactionRoot 'config.json'), ($config | ConvertTo-Json -Compress))
        [IO.File]::WriteAllText((Join-Path $transactionRoot 'result.txt'), "更新已成功，旧版清理未完成。请关闭占用文件的程序后重试。`r`n$failure")
        exit 1
    }
    try {
        if ($newProcess) {
            $newProcess.Refresh()
            if (-not $newProcess.HasExited) {
                Stop-Process -Id $newProcess.Id -Force
                $newProcess.WaitForExit()
            }
        }
        if ($installed) { Move-WithRetry $target (Join-Path $transactionRoot 'failed') }
        if ($movedOld) {
            Move-WithRetry $backup $target
            Remove-Item -LiteralPath (Join-Path $transactionRoot 'installed') -ErrorAction SilentlyContinue
            $env:PYINSTALLER_RESET_ENVIRONMENT = '1'
            $null = Start-Yecatz "更新失败，已恢复旧版本。详细记录保存在 $transactionRoot。$failure"
        } elseif (-not $oldProcess -or $oldProcess.HasExited) {
            $env:PYINSTALLER_RESET_ENVIRONMENT = '1'
            $null = Start-Yecatz "更新失败，已重新启动原版本。详细记录保存在 $transactionRoot。$failure"
        }
        [IO.File]::WriteAllText((Join-Path $transactionRoot 'result.txt'), "更新失败，原版本已保留或恢复。`r`n$failure")
    } catch {
        [IO.File]::WriteAllText((Join-Path $transactionRoot 'result.txt'), "自动恢复未完成，旧版保存在 previous 目录。`r`n$failure`r`n$($_.Exception.Message)")
    }
    exit 1
}
