# Generalize the image so every VMware linked clone gets its own unique
# machine SID on first boot, instead of all clones sharing the SID baked
# into this base image (which breaks AD security-descriptor handling once
# more than one clone joins/promotes in the same forest - confirmed by
# comparing Get-LocalUser Administrator SIDs across clones of an
# un-sysprepped win11 box: identical S-1-5-21-... prefix on every clone).
#
# unattend-specialize.xml (copied to C:\Windows\Panther\unattend.xml here)
# is what sysprep applies automatically on each clone's first post-clone
# boot to recreate the "vagrant" account and re-run enable-winrm.ps1, since
# generalize wipes local accounts and WinRM's machine-specific config.
New-Item -ItemType Directory -Path 'C:\Windows\Setup\Scripts' -Force | Out-Null
Copy-Item -Path 'A:\enable-winrm.ps1' -Destination 'C:\Windows\Setup\Scripts\enable-winrm.ps1' -Force
Copy-Item -Path 'A:\unattend-specialize.xml' -Destination 'C:\Windows\Panther\unattend.xml' -Force

# Launched detached (not awaited) so this script - and therefore the WinRM
# command Packer is waiting on - returns and reports success *before* the
# connection gets cut by the shutdown. Awaiting it directly would race the
# shutdown against WinRM's response, and Packer would see that as the
# provisioner failing even though sysprep itself succeeded.
Start-Process -FilePath "$env:WINDIR\System32\Sysprep\sysprep.exe" `
  -ArgumentList "/generalize", "/oobe", "/shutdown", "/unattend:C:\Windows\Panther\unattend.xml" `
  -NoNewWindow
