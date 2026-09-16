# Run in Windows PowerShell while DP-in finger control works. Read-only.
# Outputs hardware/compatible IDs and driver names, never device serials or user names.
param([string]$OutputPath = (Join-Path $PWD 'xiaomi-input-windows.json'))
$ErrorActionPreference = 'Stop'
function Read-DeviceProperty($DeviceId, $Key) {
    try { return (Get-PnpDeviceProperty -InstanceId $DeviceId -KeyName $Key -ErrorAction Stop).Data }
    catch { return $null }
}
$devices = @(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '^(HID|USB)\\VID_2717&' })
$result = @($devices | ForEach-Object {
    [ordered]@{
        Name = $_.FriendlyName
        Class = $_.Class
        Status = $_.Status
        # The final instance path component can contain a serial; deliberately omit it.
        HardwarePrefix = (($_.InstanceId -split '\\')[0..1] -join '\')
        HardwareIds = @(Read-DeviceProperty $_.InstanceId 'DEVPKEY_Device_HardwareIds')
        CompatibleIds = @(Read-DeviceProperty $_.InstanceId 'DEVPKEY_Device_CompatibleIds')
        DriverService = Read-DeviceProperty $_.InstanceId 'DEVPKEY_Device_Service'
        DriverProvider = Read-DeviceProperty $_.InstanceId 'DEVPKEY_Device_DriverProvider'
        DriverVersion = Read-DeviceProperty $_.InstanceId 'DEVPKEY_Device_DriverVersion'
    }
})
ConvertTo-Json -InputObject $result -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Saved $($result.Count) Xiaomi interfaces to $OutputPath"
Write-Host 'Compatible ID UP:000D_U:0004 = Touch Screen; UP:000D_U:0002 = Pen.'
Write-Host 'This inventory is not a USB capture or a complete HID report descriptor.'
