#############################################################################################
## Description: Create a CSV report with disk information from one or more Windows systems
##
## Author: Matteo Z.
#############################################################################################

# Enables advanced parameter handling and sets 'ReuseCredential' as the default parameter set.
[CmdletBinding(DefaultParameterSetName = 'ReuseCredential')]
param (
	[Parameter(Mandatory = $false)]
	[Alias('H', 'remote_host')]
	[string] $RemoteHost,

	[Parameter(Mandatory = $false)]
	[Alias('P', 'remote_path')]
	[string] $RemotePath,

	[Parameter(Mandatory = $false)]
	[Alias('system_list')]
	[ValidateNotNullOrEmpty()]
	[string] $SystemList = 'C:\temp\system.txt',

	[Parameter(Mandatory = $false)]
	[Alias('path_export')]
	[ValidateNotNullOrEmpty()]
	[string] $PathExport = 'C:\temp\diskExport',

	# Declares an optional credential parameter belonging to the 'ProvidedCredential' parameter set.
	# PSCredential stores a username and a password represented as a SecureString.
	[Parameter(Mandatory = $false, ParameterSetName = 'ProvidedCredential')]
	[System.Management.Automation.PSCredential] $Credential,

	[Parameter(Mandatory = $true, ParameterSetName = 'AlwaysPrompt')]
	[switch] $AskAlwaysCred,

	# Displays usage information with -Help.
	[switch] $Help,

	# Accepts the literal --help argument.
	[Parameter(Position = 0)]
	[ValidateSet('--help')]
	[string] $HelpOption
)

# Enables the latest strict-mode rules supported by the running PowerShell version,
# catching issues such as uninitialized variables and references to nonexistent properties.
Set-StrictMode -Version Latest

$script:LogPath = $null
$script:SharedCredential = $null

function Show-Usage {
	Write-Host -ForegroundColor Red "`nDescription:"
	Write-Host '   Creates a CSV file containing total, used and free space for fixed disks.'
	Write-Host '   Optionally copies the resulting file to another Windows system.'
	Write-Host "`n   Systems file: $SystemList"
	Write-Host "   CSV directory: $script:CsvDirectory"
	Write-Host "   Log directory: $script:LogDirectory"
	Write-Host "`n   Systems file format: <hostname1>,<IP address1>"
	Write-Host '                        ...'
	Write-Host '                        <hostnameN>,<IP addressN>'
	Write-Host -ForegroundColor Red "`nUsage:"
	Write-Host "  1) $script:ScriptName"
	Write-Host "  2) $script:ScriptName -H <remote host> -P <remote path>"
	Write-Host "  3) $script:ScriptName -AskAlwaysCred"
	Write-Host "  4) $script:ScriptName -Credential <credential>"
	Write-Host -ForegroundColor Red "`nOptions:"
	Write-Host '  -H, -RemoteHost       Host to which the CSV is copied.'
	Write-Host '  -P, -RemotePath       Absolute destination path, for example C:\temp.'
	Write-Host '  -SystemList           Systems file. Default: C:\temp\system.txt.'
	Write-Host '  -PathExport           Base output directory. Default: C:\temp\diskExport.'
	Write-Host '  -Credential           Credential reused for remote operations.'
	Write-Host '  -AskAlwaysCred         Ask for credentials for every remote system.'
	Write-Host '  -Help, --help          Display usage information and exit.'
	Write-Host ''
}

function Write-Log {
	param (
		[Parameter(Mandatory)]
		[string] $Message,

		[ValidateSet('INFO', 'WARNING', 'ERROR')]
		[string] $Level = 'INFO'
	)

	if ([string]::IsNullOrWhiteSpace($script:LogPath)) {
		return
	}

	$entry = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
	Add-Content -LiteralPath $script:LogPath -Value $entry -Encoding UTF8 -ErrorAction Stop
}

function Initialize-ExportDirectory {
	param (
		[Parameter(Mandatory)]
		[string[]] $Path
	)

	foreach ($item in $Path) {
		if (Test-Path -LiteralPath $item -PathType Container) {
			continue
		}

		try {
			Write-Host "The path '$item' does not exist. Creating it..."
			New-Item -Path $item -ItemType Directory -Force -ErrorAction Stop | Out-Null
		}
		catch {
			Write-Host -ForegroundColor Red "Failed to create directory '$item': $($_.Exception.Message)"
			return $false
		}
	}

	return $true
}

function Test-IsLocalComputer {
	param (
		[Parameter(Mandatory)]
		[string] $ComputerName,

		[string] $IPAddress
	)

	$localNames = @('.', 'localhost', '127.0.0.1', '::1', $env:COMPUTERNAME)

	if ($localNames -contains $ComputerName -or
		$ComputerName.Split('.')[0] -eq $env:COMPUTERNAME -or
		(-not [string]::IsNullOrWhiteSpace($IPAddress) -and $localNames -contains $IPAddress)) {
		return $true
	}

	if (-not [string]::IsNullOrWhiteSpace($IPAddress)) {
		try {
			$localAddresses = Get-NetIPAddress -AddressState Preferred -ErrorAction Stop |
				Select-Object -ExpandProperty IPAddress
			if ($localAddresses -contains $IPAddress) {
				return $true
			}
		}
		catch {
			Write-Log -Level WARNING -Message "Unable to retrieve local IP addresses: $($_.Exception.Message)"
		}
	}

	return $false
}

function Get-RetrievalCredential {
	param (
		[Parameter(Mandatory)]
		[string] $ComputerName
	)

	# Credential precedence:
	# 1. use the explicitly supplied credential;
	# 2. prompt for every host when AskAlwaysCred is set;
	# 3. otherwise prompt once and cache the credential for this script execution.
	if ($null -ne $Credential) {
		return $Credential
	}

	if ($AskAlwaysCred) {
		return Get-Credential -Message "Enter the credential for '$ComputerName'"
	}

	if ($null -eq $script:SharedCredential) {
		$script:SharedCredential = Get-Credential -Message 'Enter the credential for the remote systems'
	}

	return $script:SharedCredential
}

function Get-DiskInformation {
	param (
		[Parameter(Mandatory)]
		[string] $System,

		[Parameter(Mandatory)]
		[string] $IPAddress
	)

	Write-Log -Message "Retrieving fixed disks (DriveType = 3) from '$System' ($IPAddress)."

	$query = {
		$logicalDisks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop

		foreach ($logicalDisk in $logicalDisks) {
			$totalSpace = if ($null -eq $logicalDisk.Size) {
				$null
			} else {
				[math]::Round($logicalDisk.Size / 1GB, 2)
			}

			$freeSpace = if ($null -eq $logicalDisk.FreeSpace) {
				$null
			} else {
				[math]::Round($logicalDisk.FreeSpace / 1GB, 2)
			}

			$usedSpace = if ($null -eq $logicalDisk.Size -or $null -eq $logicalDisk.FreeSpace) {
				$null
			} else {
				[math]::Round(($logicalDisk.Size - $logicalDisk.FreeSpace) / 1GB, 2)
			}

			[PSCustomObject]@{
				DeviceID         = $logicalDisk.DeviceID
				Description      = $logicalDisk.Description
				FileSystem       = $logicalDisk.FileSystem
				'TotalSpace(GB)' = $totalSpace
				'UsedSpace(GB)'  = $usedSpace
				'FreeSpace(GB)'  = $freeSpace
			}
		}
	}

	try {
		if (Test-IsLocalComputer -ComputerName $System -IPAddress $IPAddress) {
			$result = @(& $query)
		}
		else {
			$remoteCredential = Get-RetrievalCredential -ComputerName $System
			$result = @(Invoke-Command -ComputerName $IPAddress -Credential $remoteCredential `
				-ScriptBlock $query -ErrorAction Stop)
		}
	}
	catch {
		$message = "Unable to retrieve disk information from '$System' ($IPAddress): $($_.Exception.Message)"
		Write-Log -Level ERROR -Message $message
		Write-Host -ForegroundColor Red $message
		return
	}

	if ($result.Count -eq 0) {
		Write-Log -Level WARNING -Message "No fixed disks were returned by '$System' ($IPAddress)."
		return
	}

	foreach ($item in $result) {
		# Rebuild each result instead of exporting the deserialized remoting object.
		# This keeps PowerShell remoting metadata out of the CSV.
		[PSCustomObject]@{
			System           = $System
			'IP address'     = $IPAddress
			Disk             = if ($null -eq $item.DeviceID) { 'NotFound' } else { $item.DeviceID }
			Description      = $item.Description
			Filesystem       = $item.FileSystem
			'TotalSpace(GB)' = if ($null -eq $item.'TotalSpace(GB)') { 'NotFound' } else { $item.'TotalSpace(GB)' }
			'UsedSpace(GB)'  = if ($null -eq $item.'UsedSpace(GB)') { 'NotFound' } else { $item.'UsedSpace(GB)' }
			'FreeSpace(GB)'  = if ($null -eq $item.'FreeSpace(GB)') { 'NotFound' } else { $item.'FreeSpace(GB)' }
		}
	}
}

function Export-DiskReport {
	param (
		[Parameter(Mandatory)]
		[string[]] $FileContent,

		[Parameter(Mandatory)]
		[string] $Destination
	)

	$diskInformation = @(
		foreach ($row in $FileContent) {
			if ([string]::IsNullOrWhiteSpace($row) -or $row.TrimStart().StartsWith('#')) {
				continue
			}

			$fields = $row.Split([char] ',')
			if ($fields.Count -ne 2) {
				Write-Log -Level WARNING -Message "Skipped malformed row: '$row'."
				Write-Host -ForegroundColor Yellow "Skipped malformed row: '$row'."
				continue
			}

			$system = $fields[0].Trim()
			$ipAddress = $fields[1].Trim()
			# TryParse accepts both IPv4 and IPv6 and avoids throwing on malformed rows.
			$parsedAddress = $null
			$isValidAddress = [System.Net.IPAddress]::TryParse($ipAddress, [ref] $parsedAddress)

			if ([string]::IsNullOrWhiteSpace($system) -or -not $isValidAddress) {
				Write-Log -Level WARNING -Message "Skipped invalid system or IP address: '$row'."
				Write-Host -ForegroundColor Yellow "Skipped invalid system or IP address: '$row'."
				continue
			}

			Write-Host -ForegroundColor Green "Analyzing $system ($ipAddress)..."
			Get-DiskInformation -System $system -IPAddress $ipAddress
		}
	)

	if ($diskInformation.Count -eq 0) {
		Write-Log -Level ERROR -Message 'No disk information was collected; the CSV was not created.'
		return $false
	}

	try {
		$diskInformation | Export-Csv -LiteralPath $Destination -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
		Write-Log -Message "CSV report created: '$Destination'."
		return $true
	}
	catch {
		Write-Log -Level ERROR -Message "Unable to create CSV '$Destination': $($_.Exception.Message)"
		Write-Host -ForegroundColor Red "Unable to create CSV '$Destination': $($_.Exception.Message)"
		return $false
	}
}

function Copy-DiskReport {
	param (
		[Parameter(Mandatory)]
		[string] $Source,

		[Parameter(Mandatory)]
		[string] $ComputerName,

		[Parameter(Mandatory)]
		[string] $Destination
	)

	if ($Destination -notmatch '^[A-Za-z]:\\') {
		throw "RemotePath must be an absolute drive path, for example 'C:\temp'."
	}

	if (Test-IsLocalComputer -ComputerName $ComputerName) {
		if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
			throw "Destination directory '$Destination' does not exist."
		}

		Copy-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
		Write-Log -Message "CSV report copied to local path '$Destination'."
		return
	}

	# Copy through a PowerShell session instead of constructing an administrative share such as C$.
	$session = $null
	try {
		$sessionParameters = @{
			ComputerName = $ComputerName
			ErrorAction  = 'Stop'
		}

		# Reuse the credential already supplied or collected while querying systems.
		# If no credential exists, New-PSSession uses the current Windows identity.
		$copyCredential = if ($null -ne $Credential) {
			$Credential
		} elseif ($AskAlwaysCred) {
			Get-Credential -Message "Enter the credential for destination '$ComputerName'"
		} else {
			$script:SharedCredential
		}

		if ($null -ne $copyCredential) {
			$sessionParameters.Credential = $copyCredential
		}

		$session = New-PSSession @sessionParameters
		$destinationExists = Invoke-Command -Session $session -ScriptBlock {
			param ($Path)
			Test-Path -LiteralPath $Path -PathType Container
		} -ArgumentList $Destination -ErrorAction Stop

		if (-not $destinationExists) {
			throw "Destination directory '$Destination' does not exist on '$ComputerName'."
		}

		Copy-Item -LiteralPath $Source -Destination $Destination -ToSession $session -ErrorAction Stop
		Write-Log -Message "CSV report copied to '$ComputerName':'$Destination'."
		Write-Host -ForegroundColor Green "The CSV was copied to $ComputerName`:$Destination."
	}
	catch {
		Write-Log -Level ERROR -Message "Unable to copy the CSV to '$ComputerName':'$Destination': $($_.Exception.Message)"
		Write-Host -ForegroundColor Red "Unable to copy the CSV to ${ComputerName}:${Destination}: $($_.Exception.Message)"
	}
	finally {
		if ($null -ne $session) {
			Remove-PSSession -Session $session
		}
	}
}

########## MAIN ##########

$script:ScriptName = $MyInvocation.MyCommand.Name
$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$script:LogDirectory = Join-Path -Path $PathExport -ChildPath 'Log'
$script:CsvDirectory = Join-Path -Path $PathExport -ChildPath 'CSV'

# Displays help and stops before reading files or starting the export.
if ($Help -or $HelpOption -eq '--help') {
    Show-Usage
    return
}

$hasRemoteHost = -not [string]::IsNullOrWhiteSpace($RemoteHost)
$hasRemotePath = -not [string]::IsNullOrWhiteSpace($RemotePath)
# XOR is true when only one of the two related parameters was supplied.
if ($hasRemoteHost -xor $hasRemotePath) {
	throw 'RemoteHost and RemotePath must be specified together.'
}

if ($hasRemotePath -and $RemotePath -notmatch '^[A-Za-z]:\\') {
	throw "RemotePath must be an absolute drive path, for example 'C:\temp'."
}

if (-not (Test-Path -LiteralPath $SystemList -PathType Leaf)) {
	Write-Host -ForegroundColor Yellow "`nThe systems file '$SystemList' was not found."
	Show-Usage
	return
}

try {
	$fileContent = @(Get-Content -LiteralPath $SystemList -ErrorAction Stop)
}
catch {
	Write-Host -ForegroundColor Red "Unable to read '$SystemList': $($_.Exception.Message)"
	return
}

if ($fileContent.Count -eq 0 -or -not ($fileContent | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
	Write-Host -ForegroundColor Yellow "`nThe systems file '$SystemList' is empty."
	Show-Usage
	return
}

$directories = @($PathExport, $script:LogDirectory, $script:CsvDirectory)

if (-not (Initialize-ExportDirectory -Path $directories)) {
	return
}

$script:LogPath = Join-Path -Path $script:LogDirectory -ChildPath "log-$timestamp.log"
$csvPath = Join-Path -Path $script:CsvDirectory -ChildPath "diskExport-$timestamp.csv"
Write-Log -Message "Starting disk export using systems file '$SystemList'."

if (-not (Export-DiskReport -FileContent $fileContent -Destination $csvPath)) {
	Write-Host -ForegroundColor Red "`nThe CSV report was not created. See '$script:LogPath'."
	return
}

Write-Host "`nThe CSV report was created: $csvPath"

if ($hasRemoteHost) {
	Copy-DiskReport -Source $csvPath -ComputerName $RemoteHost -Destination $RemotePath
}

Write-Host "The log file was created: $script:LogPath"