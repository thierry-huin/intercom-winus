<#
.SYNOPSIS
Opens the Windows firewall so the Winus Intercom backend can send audio
(mediasoup PlainTransport RTP over UDP) to the tie-line-bridge running on
this PC.

.DESCRIPTION
The backend allocates a random UDP port on the bridge side per session, so
we can't pin a single destination port. This script adds an inbound rule
that allows UDP from the backend's IP to any port on this PC, which is
enough for PlainTransport audio to flow in.

If you pass -PythonPath the rule is scoped to that executable only (safer).

.PARAMETER ServerIp
IP address (or comma-separated list) of the Winus Intercom backend. Example:
"192.168.1.10" or "192.168.1.10,10.0.0.5".

.PARAMETER PythonPath
Optional. Full path to python.exe that runs the tie-line-bridge. If
provided, the rule is bound to that program only.

.PARAMETER RuleName
Optional. Name of the firewall rule. Defaults to "Winus Intercom Bridge".

.PARAMETER Remove
Switch. If set, removes any existing rule with the given name and exits.

.EXAMPLE
# Allow UDP from the server (simplest)
.\winus-bridge-firewall.ps1 -ServerIp 192.168.1.10

.EXAMPLE
# Restrict to the python interpreter that runs the bridge
.\winus-bridge-firewall.ps1 -ServerIp 192.168.1.10 `
  -PythonPath "C:\Users\Thierry\AppData\Local\Programs\Python\Python312\python.exe"

.EXAMPLE
# Uninstall the rule
.\winus-bridge-firewall.ps1 -Remove

.NOTES
Run in an elevated PowerShell (Run as Administrator).
#>

param(
    [Parameter(Mandatory = $false)]
    [string[]]$ServerIp,

    [Parameter(Mandatory = $false)]
    [string]$PythonPath,

    [Parameter(Mandatory = $false)]
    [string]$RuleName = "Winus Intercom Bridge",

    [Parameter(Mandatory = $false)]
    [switch]$Remove
)

# --- Require administrator ---------------------------------------------
$currentUser = [Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator. Right-click PowerShell -> 'Run as administrator' and re-run."
    exit 1
}

# --- Remove existing rules (same display name) -------------------------
$existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Removing previous rules named '$RuleName'..."
    $existing | Remove-NetFirewallRule -Confirm:$false
}

if ($Remove) {
    Write-Host "OK, firewall rule '$RuleName' removed (if it existed)."
    exit 0
}

if (-not $ServerIp -or $ServerIp.Count -eq 0) {
    Write-Error "Missing -ServerIp. Example: -ServerIp 192.168.1.10"
    exit 1
}

# --- Create inbound rule ------------------------------------------------
$ruleArgs = @{
    DisplayName = $RuleName
    Direction   = 'Inbound'
    Action      = 'Allow'
    Protocol    = 'UDP'
    RemoteAddress = $ServerIp
    Profile     = 'Any'
    Description = 'Allow RTP audio from Winus Intercom backend (PlainTransport).'
}

if ($PythonPath) {
    if (-not (Test-Path $PythonPath)) {
        Write-Error "Python executable not found: $PythonPath"
        exit 1
    }
    $ruleArgs.Program = $PythonPath
}

New-NetFirewallRule @ruleArgs | Out-Null

Write-Host "OK, firewall rule added:"
Write-Host "   Name        : $RuleName"
Write-Host "   Direction   : Inbound"
Write-Host "   Protocol    : UDP"
Write-Host "   RemoteHosts : $($ServerIp -join ', ')"
if ($PythonPath) { Write-Host "   Program     : $PythonPath" }
Write-Host ""
Write-Host "You can now start the tie-line-bridge. Test with:"
Write-Host "   Get-NetFirewallRule -DisplayName '$RuleName' | Get-NetFirewallPortFilter"
