# One-time native mstsc setup; leaves all other RDP host profiles alone.
param(
  [string]$HostName = "127.0.0.1",
  [int]$Port = 3389,
  [string]$MacUser = "ahang",
  [string]$KnownGoodRdp = "",
  [switch]$SkipCredentialPrompt
)
$ErrorActionPreference = "Stop"
if ($HostName -notmatch '^[a-zA-Z0-9.:-]+$' -or $Port -lt 1 -or $Port -gt 65535 -or
    [string]::IsNullOrWhiteSpace($MacUser) -or $MacUser.Contains([char]10)) {
  throw "Invalid hostname, port or user name"
}
# Prefer the exact existing Windows profile that already worked.
# Do not silently rebuild it: that would discard evidence and other options.
# Never overwrite Documents/Default.rdp; unrelated RDP hosts need NLA.
$folder = Join-Path $env:APPDATA "MacRemote"
New-Item -Path $folder -ItemType Directory -Force | Out-Null
if ($KnownGoodRdp) {
  $sourceRdp = (Resolve-Path -LiteralPath $KnownGoodRdp).Path
  $profileText = [IO.File]::ReadAllText($sourceRdp)
  $configuredHost = [regex]::Match($profileText,
      '(?m)^full address:s:([^\r\n]+)').Groups[1].Value
  if (-not $configuredHost) { throw "Known-good RDP profile has no full address" }
  $HostName = $configuredHost
  $configuredUser = [regex]::Match($profileText,
      '(?m)^username:s:([^\r\n]+)').Groups[1].Value
  if ($configuredUser) { $MacUser = $configuredUser }
  # Copy the exact proven working settings to a permanent location, so
  # moving or deleting the downloaded zip will not break the shortcut.
  $rdpFile = Join-Path $folder "MacRemote.rdp"
  if ([IO.Path]::GetFullPath($sourceRdp) -ne [IO.Path]::GetFullPath($rdpFile)) {
    if (Test-Path -LiteralPath $rdpFile) {
      $backup = "$rdpFile.$(Get-Date -Format yyyyMMddHHmmss).bak"
      Copy-Item -LiteralPath $rdpFile -Destination $backup
    }
    Copy-Item -LiteralPath $sourceRdp -Destination $rdpFile -Force
  }
} else {
$rdpFile = Join-Path $folder "MacRemote.rdp"
$lines = @(
  "full address:s:$HostName",
  "server port:i:$Port",
  "username:s:$MacUser",
  "prompt for credentials:i:0",
  "prompt for credentials on client:i:1",
  "enablecredsspsupport:i:0",
  "negotiate security layer:i:1",
  "authentication level:i:2",
  "session bpp:i:32"
)
$newContent = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
if (Test-Path -LiteralPath $rdpFile) {
  $old = [IO.File]::ReadAllText($rdpFile)
  if ($old -ne $newContent) {
    $stamp = Get-Date -Format "yyyyMMddHHmmss"
    $backup = "$rdpFile.$stamp.bak"
    Copy-Item -LiteralPath $rdpFile -Destination $backup
    Write-Host "Previous MacRemote profile backed up: $backup"
  }
}
[IO.File]::WriteAllText($rdpFile,$newContent,[Text.Encoding]::Unicode)
}
$startMenu = [Environment]::GetFolderPath('Programs')
$shortcutFile = Join-Path $startMenu "MacRemote.lnk"
$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutFile)
$shortcut.TargetPath = Join-Path $env:WINDIR 'System32\mstsc.exe'
$shortcut.Arguments = ('"{0}"' -f $rdpFile)
$shortcut.WorkingDirectory = $folder
$shortcut.Description = 'MacRemote with native Windows mstsc'
$shortcut.Save()

if (-not $SkipCredentialPrompt) {
  Write-Host "Save the Mac password in Windows Credential Manager."
  Write-Host "The next prompt is Windows cmdkey; do not put passwords in scripts."
  & cmdkey.exe "/generic:TERMSRV/$HostName" "/user:$MacUser"
  if ($LASTEXITCODE -ne 0) { throw "Credential Manager setup failed" }
}
Write-Host "MacRemote is now available in the Start menu."
Write-Host "RDP profile: $rdpFile"
