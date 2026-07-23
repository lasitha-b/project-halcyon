# Bootstraps WinRM so Packer (and later Vagrant/Ansible) can drive the VM.
# Runs once via FirstLogonCommands in autounattend.xml.
#
# Without this, Windows hands remote WinRM/NTLM connections from the local
# "vagrant" admin account a filtered, non-elevated token (the default
# remote-UAC restriction for any admin account other than the built-in
# RID-500 Administrator), and WinRM rejects auth outright even with the
# correct password.
reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f
winrm quickconfig -quiet
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="1024"}'
netsh advfirewall firewall add rule name="WinRM-HTTP" dir=in localport=5985 protocol=TCP action=allow
Set-Service -Name WinRM -StartupType Automatic
Restart-Service WinRM
