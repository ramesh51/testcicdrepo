<#
.SYNOPSIS
  Start or Stop services across multiple remote servers, handling StopPending and missing services.

.PARAMETERS
  -action          : 'start' or 'stop'
  -remoteHosts     : Array of remote hostnames/IPs
  -vm_Username     : Windows username
  -vm_Password     : Plaintext password
  -serviceNames    : Array of service names (e.g., "['W3SVC','Spooler','FakeService']")
#>

param (
    [string]$action,
    [string[]]$remoteHosts,
    [string]$vm_Username,
    [string]$vm_Password,
    [string[]]$serviceNames
)

$TimeoutSeconds = 120
$RetryInterval = 5

$vm_SecurePass = ConvertTo-SecureString -AsPlainText $vm_Password -Force
$cred = New-Object System.Management.Automation.PSCredential ($vm_Username, $vm_SecurePass)

foreach ($remoteHost in $remoteHosts) {
    Write-Output "🔧 Connecting to remote host: $remoteHost"

    try {
        $sess = New-PSSession -ComputerName $remoteHost -Credential $cred
    }
    catch {
        Write-Error "❌ Could not establish session with $remoteHost. Skipping..."
        continue
    }

    foreach ($svc in $serviceNames) {
        Write-Output "`n▶️ [$remoteHost] Checking service: $svc"

        $scriptBlock = {
            param($ServiceName, $ServiceAction, $ExpectedStatus, $TimeoutSeconds, $RetryInterval)

            try {
                $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
                if (-not $service) {
                    Write-Output "❌ PS: Service '$ServiceName' is NOT available on this server."
                    return
                }

                Write-Output "✅ PS: Found service '$ServiceName' - current status: $($service.Status)"

                if ($ServiceAction -eq "stop" -and $service.Status -ne "Stopped") {
                    Write-Output "➡️ PS: Stopping '$ServiceName'"
                    Stop-Service -Name $ServiceName -Force
                } elseif ($ServiceAction -eq "start" -and $service.Status -ne "Running") {
                    Write-Output "➡️ PS: Starting '$ServiceName'"
                    Start-Service -Name $ServiceName
                } else {
                    Write-Output "ℹ️ PS: '$ServiceName' already in target state: $ExpectedStatus"
                }

                $startTime = Get-Date
                $endTime = $startTime.AddSeconds($TimeoutSeconds)

                while ((Get-Service -Name $ServiceName).Status -ne $ExpectedStatus) {
                    $currentStatus = (Get-Service -Name $ServiceName).Status
                    Write-Output "⏳ PS: Waiting... '$ServiceName' status: $currentStatus"

                    if ($currentStatus -eq "StopPending") {
                        Write-Output "⚠️ PS: '$ServiceName' stuck in StopPending — attempting to kill process"

                        $query = "SELECT ProcessId FROM Win32_Service WHERE Name='$ServiceName'"
                        $pid = (Get-WmiObject -Query $query).ProcessId
                        if ($pid) {
                            Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
                            Write-Output "✅ PS: Killed stuck process ID $pid for '$ServiceName'"
                        } else {
                            Write-Output "❌ PS: Could not resolve PID for '$ServiceName'"
                        }
                    }

                    if ((Get-Date) -gt $endTime) {
                        throw "⏰ Timeout - '$ServiceName' did not reach $ExpectedStatus. Final status: $currentStatus"
                    }

                    Start-Sleep -Seconds $RetryInterval
                }

                Write-Output "✅ PS: '$ServiceName' successfully reached $ExpectedStatus"
            }
            catch {
                Write-Error "❌ PS: Error managing '$ServiceName': $_"
            }
        }

        try {
            if ($action -eq "start") {
                Invoke-Command -Session $sess -ScriptBlock $scriptBlock -ArgumentList $svc, "start", "Running", $TimeoutSeconds, $RetryInterval
            } elseif ($action -eq "stop") {
                Invoke-Command -Session $sess -ScriptBlock $scriptBlock -ArgumentList $svc, "stop", "Stopped", $TimeoutSeconds, $RetryInterval
            } else {
                Write-Error "❌ Invalid action: $action"
            }
        }
        catch {
            Write-Error "❌ Invoke-Command failed for service $svc on $remoteHost: $_"
        }
    }

    # Clean up session
    Remove-PSSession $sess
}
