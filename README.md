# Windows Disk Export

The program collects fixed logical disk information from one or more Windows computers and exports a CSV report containing total, used, and free space. It supports local queries, remote queries through PowerShell Remoting, and an optional copy of the completed report to another Windows computer.

## Requirements

- Windows with PowerShell 5.1 or later and the `Get-CimInstance` cmdlet available.
- A system list containing a hostname and IP address for each computer.
- Read access to disk information and write access to the local output directory.
- For remote queries: PowerShell Remoting/WinRM configured and reachable on the targets, with credentials authorized to use the remote session and query CIM.
- For optional remote delivery: PowerShell Remoting access to the destination computer and an existing, writable destination directory.

Local queries run in the current PowerShell process without a remote session or credential prompt. Remote report delivery uses `Copy-Item -ToSession` over PowerShell Remoting.

## Configure the system list

Create `C:\temp\system.txt`, or supply another file with `-SystemList`:

```text
# hostname,IP address
localhost,127.0.0.1
host1,<IP1>
host2,<IP2>
```

- Each entry must contain exactly two comma-separated fields: a nonempty hostname and a valid IPv4 or IPv6 address.
- Surrounding whitespace is removed. Blank lines and lines beginning with `#` are ignored.
- Malformed entries are skipped with a warning.
- Remote disk queries connect to the **IP address in the second field**. The hostname remains the label used in credential prompts, log messages, and the CSV `System` column.
- Both fields also help identify the local computer. Use the actual destination name and IP; a local name or local IP can cause the entry to be queried locally.

The program recognizes common local aliases, the local computer name and its fully qualified form, and entries whose IP matches a preferred local network address. Systems are processed sequentially.

## Connect two Windows VMs

The following example uses a source VM that runs the program and a target VM named `host2` at `<IP2>`. It covers a workgroup connection over WinRM HTTP. Run configuration commands in **Windows PowerShell as Administrator** on the VM indicated in each step.

### 1. Enable remoting on the target VM

On `host2`, verify its identity and enable remoting:

```powershell
hostname
Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress
Enable-PSRemoting -Force
Get-Service WinRM
Test-WSMan localhost
```

If a public network profile prevents configuration and both VMs are on the same subnet, use `Enable-PSRemoting -SkipNetworkProfileCheck -Force`. This permits access from the local subnet on public networks. See [Microsoft's Enable-PSRemoting documentation](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/enable-psremoting?view=powershell-5.1).

### 2. Configure the source VM

Check connectivity to the target's default WinRM HTTP port:

```powershell
Test-NetConnection -ComputerName '<IP2>' -Port 5985
```

`TcpTestSucceeded` should be `True`. Otherwise, check the target's WinRM service, Windows Firewall, and the network/firewall configuration between the VMs.

Start the local WinRM service before updating TrustedHosts:

```powershell
Start-Service WinRM
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '<IP2>' -Concatenate -Force
(Get-Item WSMan:\localhost\Client\TrustedHosts).Value
```

If the local service is disabled, run `Set-Service WinRM -StartupType Manual`, then retry `Start-Service WinRM`.

TrustedHosts must contain the value actually used for the connection. The current program queries disks by IP, so adding only `host2` does not cover `<IP2>`. `-Concatenate` preserves existing entries. Limit trust to the required targets: TrustedHosts does not verify the remote computer's identity. See [Microsoft's WinRM configuration guidance](https://learn.microsoft.com/en-us/windows/win32/winrm/installation-and-configuration-for-windows-remote-management).

### 3. Test credentials and disk access from the source VM

Use an existing local administrator account on the target VM, with a nonempty password. Replace `username` with that account's name:

```powershell
$cred = Get-Credential -UserName 'host2\username' -Message 'Credentials for the target VM'

Invoke-Command -ComputerName '<IP2>' -Credential $cred -ScriptBlock {
    hostname
    whoami
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' |
        Select-Object DeviceID, FileSystem, Size, FreeSpace
} -ErrorAction Stop
```

This should return the target identity and its fixed disks. If an ordinary local administrator account receives `Access is denied` despite correct credentials and group membership, remote UAC filtering may be responsible. On the **target VM**, the following setting allows local administrators to use their full administrative token remotely:

```powershell
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name 'LocalAccountTokenFilterPolicy' -PropertyType DWord -Value 1 -Force
```

This changes remote UAC filtering for all local administrator accounts on that VM, not just the test account. Apply it only if that behavior is appropriate for your environment. See [Microsoft's authentication guidance](https://learn.microsoft.com/en-us/windows/win32/winrm/authentication-for-remote-connections).

### 4. Run the export from the source VM

Create `C:\temp` if needed, then save the following entry in `C:\temp\system.txt`:

```text
host2,<IP2>
```

From the script directory, reuse the credential tested above:

```powershell
.\exportDiskInfo.ps1 -SystemList 'C:\temp\system.txt' -Credential $cred
```

Or request credentials separately for each remote system:

```powershell
.\exportDiskInfo.ps1 -SystemList 'C:\temp\system.txt' -AskAlwaysCred
```

Reports and logs are saved on the source VM. `-RemoteHost` and `-RemotePath` are only needed to copy the completed report elsewhere; the systems to query come from `system.txt`.

**Domain and HTTPS connections:** Kerberos cannot authenticate an IP-based connection. The current program uses the default HTTP transport and has no `-UseSSL` parameter; an HTTPS listener alone does not switch its connections to HTTPS. Using Kerberos by hostname or adding HTTPS support requires adapting the connection calls. See [Microsoft's remoting troubleshooting guide](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_remote_troubleshooting?view=powershell-5.1).

## Usage

Run these examples from the directory containing the program.

### Locate and run the program

```powershell
Get-Location
Get-ChildItem -Path . -Filter *.ps1

# Program in the current directory
.\exportDiskInfo.ps1 -AskAlwaysCred

# Program in the parent directory
..\exportDiskInfo.ps1 -AskAlwaysCred

# Absolute path (replace it with the actual program location)
& 'C:\scripts\exportDiskInfo.ps1' -AskAlwaysCred
```

These are alternative ways to launch the same program. `..\` means the parent of the current working directory.

### Export using the default paths

```powershell
.\exportDiskInfo.ps1
```

This reads `C:\temp\system.txt` and writes the report and log under `C:\temp\diskExport`. Missing local output directories are created automatically.

### Use custom input and output paths

```powershell
.\exportDiskInfo.ps1 -SystemList 'C:\operations\servers.txt' -PathExport 'D:\reports\disks'
```

### Supply credentials explicitly

```powershell
$cred = Get-Credential
.\exportDiskInfo.ps1 -Credential $cred
```

### Prompt separately for each remote computer

```powershell
.\exportDiskInfo.ps1 -AskAlwaysCred
```

### Copy the completed report to another computer

```powershell
.\exportDiskInfo.ps1 -H '<IP3>' -P 'D:\reports\disks'
```

Or combine explicit credentials with custom paths:

```powershell
$cred = Get-Credential
.\exportDiskInfo.ps1 -SystemList 'C:\operations\servers.txt' -PathExport 'C:\operations\diskExport' -RemoteHost '<IP3>' -RemotePath 'D:\reports\disks' -Credential $cred
```

`-RemoteHost` and `-RemotePath` must be supplied together. The destination must be an existing directory specified as an absolute drive path, such as `C:\temp` or `D:\reports\disks`. The local CSV is retained after copying. If the destination host is recognized as local, the script performs a local copy.

Remote delivery connects using the exact name or IP passed to `-RemoteHost`. In a workgroup, ensure that value is also in TrustedHosts on the source VM. Authorizing an IP for disk queries does not automatically authorize a hostname used for report delivery.

## Parameters

| Parameter        | Aliases              | Description                                                       | Default              |
| ---------------- | -------------------- | ----------------------------------------------------------------- | -------------------- |
| `-SystemList`    | `-system_list`       | File containing the systems to query                              | `C:\temp\system.txt` |
| `-PathExport`    | `-path_export`       | Base directory for local CSV and log files                        | `C:\temp\diskExport` |
| `-RemoteHost`    | `-H`, `-remote_host` | Computer receiving a copy of the report                           | None                 |
| `-RemotePath`    | `-P`, `-remote_path` | Existing destination directory on that computer                   | None                 |
| `-Credential`    |                      | A `PSCredential` object reused for remote queries and delivery    | Prompt when needed   |
| `-AskAlwaysCred` |                      | Request credentials for each remote query and for remote delivery | Disabled             |

`-Credential` and `-AskAlwaysCred` belong to different parameter sets and cannot be combined.

## Authentication behavior

By default, the first remote query prompts for credentials, which are reused for subsequent remote queries during that run. Credentials are held in memory and are not saved to a file.

With `-Credential`, the supplied account is used for remote operations. With `-AskAlwaysCred`, each remote query prompts separately, and copying to a remote destination prompts again. Local queries always use the current Windows identity.

Creating or passing a `PSCredential` object does not validate the account: authentication occurs when the remote connection is attempted. A local-only query does not validate supplied credentials and does not prompt with `-AskAlwaysCred`. A completed CSV can still contain only the successful queries; inspect the log for failures.

## Output

Each run uses a timestamp in the format `yyyy-MM-dd_HH-mm-ss`:

```text
C:\temp\diskExport\
|-- CSV\
|   `-- diskExport-2026-09-25_19-39-31.csv
`-- Log\
    `-- log-2026-09-25_19-39-31.log
```

The report is a comma-separated UTF-8 CSV without PowerShell type information or remoting metadata. It contains one row per fixed logical disk returned by `Win32_LogicalDisk` with `DriveType = 3`.

| Column           | Description                               |
| ---------------- | ----------------------------------------- |
| `System`         | Hostname from the system list             |
| `IP address`     | IP address from the system list           |
| `Disk`           | Logical disk identifier, such as `C:`     |
| `Description`    | Description returned by CIM               |
| `Filesystem`     | File system returned by CIM, such as NTFS |
| `TotalSpace(GB)` | Total capacity                            |
| `UsedSpace(GB)`  | Total capacity minus free space           |
| `FreeSpace(GB)`  | Available space                           |

Space values are divided by PowerShell's `1GB` constant and rounded to two decimal places. The headers say `GB`, but the values use binary GiB units. Missing disk identifiers or space values are exported as `NotFound`; valid zero values remain zero.

## Example files

Examples are available in the [examples](examples/) folder:

- [system.txt](examples/system.txt): an example input file listing the systems to query.
- [CSV report](examples/diskExport/CSV/diskExport-2026-09-25_19-39-31.csv): an example of the exported disk information.
- [Log file](examples/diskExport/Log/log-2026-09-25_19-39-31.log): an example of the messages recorded during execution.

## Error handling and limitations

- Failed queries are logged, and processing continues with the next system. A report can therefore contain only a subset of the requested systems; failed hosts do not receive placeholder rows.
- If no disk information is collected, no CSV is created and no delivery is attempted.
- Only fixed logical disks exposed by the CIM query are included. The report is not a physical disk inventory and does not include removable drives, network drives, or disk health information.
- Remote copy errors are reported in the console and log; the completed local CSV remains available.
- Input-file and output-directory errors can occur before logging starts; check console output if no log is created.

## Troubleshooting

| Problem                                            | What to check                                                                                                 |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| System list is missing or empty                    | Create the file and add valid entries, or select the correct path with `-SystemList`                          |
| An entry is skipped                                | Use exactly `hostname,IP address`, with a valid IPv4 or IPv6 address                                          |
| Remote disk query fails                            | Check the IP in the second field, WinRM configuration, network access, credentials, and remoting permissions  |
| `ServerNotTrusted` or a TrustedHosts error         | Add the target IP to TrustedHosts on the source VM. A hostname entry does not cover a connection by IP.       |
| `Set-Item WSMan:\localhost\...` cannot connect     | Check the WinRM service on the source VM with `Get-Service WinRM`; start it and retry.                        |
| Direct `Invoke-Command` works but the script fails | Test with the same target IP, credentials, and source VM as the script.                                       |
| No prompt with `-AskAlwaysCred`                    | Check whether entries are recognized as local, skipped as invalid, or processing stops before a remote query. |
| Script name is not recognized                      | Check `Get-Location`, the filename, and whether the path should begin with `.\` or `..\`.                     |
| No CSV is created                                  | Inspect the log for failed queries, invalid entries, or systems returning no fixed disks                      |
| Report contains fewer systems than expected        | Check the log for individual query failures and skipped rows                                                  |
| Destination path is rejected                       | Supply both destination parameters and use an absolute drive path to an existing directory                    |
| Remote report copy fails                           | Check destination remoting access, credentials, directory existence, and write permissions                    |
| Output or log creation fails                       | Check local directory permissions and available disk space                                                    |
