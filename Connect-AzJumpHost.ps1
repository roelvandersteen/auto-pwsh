<#
.SYNOPSIS
This script identifies virtual machines and their associated Bastion hosts within specified Azure subscriptions and allows the user to connect to a VM via RDP using the selected Bastion host with EntraID authentication enabled.

.DESCRIPTION
The script performs the following steps:
1. Checks for updates and downloads the latest version if available. The script will restart itself after the update.
2. Checks if the Azure CLI is installed and the Azure Bastion extension is available and up-to-date.
3. Defines and executes a query to retrieve information about virtual machines, and Bastion hosts.
4. Converts the query results from JSON to PowerShell objects.
5. Prompts the user to select a Bastion host to connect to a virtual machine.
6. Constructs and executes an Azure CLI command to connect to the VM via RDP with EntraID authentication enabled.

.EXAMPLE
.\Connect-AzJumpHost.ps1
Prompts the user to select a Bastion host and connects to the selected VM via RDP with EntraID authentication enabled.

.NOTES
- Requires Azure CLI to be installed and authenticated.
- Executes an Azure Resource Graph query to fetch resources.
- Connects to the VM via Bastion using RDP with EntraID authentication enabled.
- Uses a public GitHub repository to check for updates and download the latest version.

.LINK
https://docs.microsoft.com/en-us/azure/azure-resource-graph/
#>

if ($PSVersionTable.PSEdition -ne "Core") {
  Write-Host -ForegroundColor Red "🛑 This script requires PowerShell Core. Please run it in a PowerShell Core session."
  return
}

$CurrentVersion = [version]"0.1.0"
$UpdateUrl = "https://raw.githubusercontent.com/roelvandersteen/auto-pwsh/refs/heads/main/Connect-AzJumpHost-LatestVersion.txt"
$ScriptUrl = "https://raw.githubusercontent.com/roelvandersteen/auto-pwsh/refs/heads/main/Connect-AzJumpHost.ps1"
$LocalPath = "$PSScriptRoot\Connect-AzJumpHost.ps1"

try {
  $LatestVersion = [version](Invoke-RestMethod -Uri $UpdateUrl)
  if ($LatestVersion -gt $CurrentVersion) {
    Write-Host "💡 Update available: $LatestVersion (current: $CurrentVersion). Downloading..."
    $tempFile = [System.IO.Path]::GetTempFileName()
    $mustRestart = $false
    try {
      Invoke-WebRequest -Uri $ScriptUrl -OutFile $tempFile -ErrorAction Stop
      Move-Item -Path $tempFile -Destination $LocalPath -Force
      $mustRestart = $true
    }
    catch {
      Remove-Item -Path $tempFile -Force
      Write-Warning "⚠️ Request failed, original file is preserved."
    }
    if ($mustRestart) {
      Write-Host "🚀 Update downloaded to $LocalPath. Restarting..."
      Start-Process -FilePath "pwsh" -ArgumentList "-NoProfile -File $LocalPath"
      return
    }
  }
}
catch {
  Write-Host "🛠️ Error checking for updates: $_"
}

if (-not (Get-Command -Name "az" -ErrorAction SilentlyContinue)) {
  Write-Host -ForegroundColor Red "🛑 Azure CLI (az) is not installed. Please install it to proceed."
  return
}

$bastionExtensionName = "bastion"
$bastionRequiredVersion = [version]"1.3.1"
$bastionExtensionInfo = az extension list --query "[? name=='$bastionExtensionName'] | [0]" | ConvertFrom-Json
if (-not $bastionExtensionInfo) {
  Write-Host "✨ Azure Bastion extension is not installed. Installing it now."
  az extension add --name $bastionExtensionName
}
else {
  $bastionCurrentVersion = [version]$bastionExtensionInfo.version
  if ($bastionCurrentVersion -lt $bastionRequiredVersion) {
    Write-Host "✨ Azure Bastion extension version $bastionRequiredVersion or higher is required. Updating."
    az extension update --name $bastionExtensionName
  }
}
$bastionExtensionInfo = az extension list --query "[? name=='$bastionExtensionName'] | [0]" | ConvertFrom-Json
if ([version]$bastionExtensionInfo.version -lt $bastionRequiredVersion) {
  Write-Host -ForegroundColor Red "🛑 Azure Bastion extension version $bastionRequiredVersion or higher is required. Auto-update failed. Try to update it manually."
  return
}

# Main script logic

$query = @"
resources
| where type == 'microsoft.compute/virtualmachines'
| project vmName = name, vmId = id, nic = tostring(properties.networkProfile.networkInterfaces[0].id), subscriptionId
| join kind=inner ( resources
         | where type == 'microsoft.network/networkinterfaces'
         | project nic = tostring(id), vnet = tostring(split(properties.ipConfigurations[0].properties.subnet.id,'/')[8]) ) on nic
| join kind=inner ( resources
         | where type == 'microsoft.network/bastionhosts'
         | project bastion = name, resourceGroup, vnet = tostring(split(properties.ipConfigurations[0].properties.subnet.id,'/')[8]) ) on vnet
| join kind=inner ( resourcecontainers
         | where type == 'microsoft.resources/subscriptions'
         | project subscription = name, subscriptionId ) on subscriptionId
| project vmName, vmId, bastion, resourceGroup, subscription, subscriptionId
| order by subscription, vmName
"@ -replace "\s+", " "

$bastions = @(az graph query -q $query |
  ConvertFrom-Json |
  Select-Object -ExpandProperty data)

if ($bastions.Length -eq 0) { Write-Warning "🚨 No Bastions/jumphosts found."; return }

$idx = 1
$choices = @($bastions |
  ForEach-Object {
    $subscription = $_.subscription
    $vmCount = ($bastions | Where-Object { $_.subscription -eq $subscription }).Count
    $label = $vmCount -gt 1 ? "&$([string]($idx++)) $($_.vmName)" : $subscription -replace "Tacx\s+", "&"
    [System.Management.Automation.Host.ChoiceDescription]::new($label, $_.vmId)
  })
$choiceIndex = $host.ui.PromptForChoice("* Select Jumphost", "Which jumphost do you want to connect to?", $choices, -1)

if ($choiceIndex -lt 0) { return }
$bastion = $bastions | Where-Object { $_.vmId -eq $choices[$choiceIndex].HelpMessage } | Select-Object -First 1

$powerState = az vm show -d --ids $($bastion.vmId) --query "powerState" | ConvertFrom-Json
if ($powerState -ne "VM running") {
  $choiceIndex = $host.ui.PromptForChoice("* Jumphost not running", "Jumphost is in state '$powerState', do you want to start it?", [System.Management.Automation.Host.ChoiceDescription[]] @("&Yes", "&No"), 0)

  if ($choiceIndex -eq 0) {
    Write-Host "This may take some time..." -ForegroundColor Magenta
    az vm start --ids $($bastion.vmId)
    Start-Sleep -Seconds 5
  }
  else {
    Write-Host "⚠️ Expect the connection to the Bastion host to fail!" -ForegroundColor Red
  }
}

Write-Host "➡️ Executing:" -ForegroundColor Green
Write-Host "az network bastion rdp ``" -ForegroundColor Blue
Write-Host "   --enable-mfa         true ``" -ForegroundColor Blue
Write-Host "   --subscription       $($bastion.subscriptionId) ``" -ForegroundColor Blue
Write-Host "   --name               $($bastion.bastion) ``" -ForegroundColor Blue
Write-Host "   --resource-group     $($bastion.resourceGroup) ``" -ForegroundColor Blue
Write-Host "   --target-resource-id $($bastion.vmId)`n" -ForegroundColor Blue

Start-Process -NoNewWindow -FilePath az -ArgumentList "network bastion rdp --enable-mfa true --subscription $($bastion.subscriptionId) --name $($bastion.bastion) --resource-group $($bastion.resourceGroup) --target-resource-id $($bastion.vmId)"
Start-Sleep -Milliseconds 2000
