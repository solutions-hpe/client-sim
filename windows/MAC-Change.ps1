$newmac=$args[0]
Remove-NetAdapterAdvancedProperty -Name "Wi-Fi" -RegistryKeyword "NetworkAddress" -AllProperties
New-NetAdapterAdvancedProperty -Name "Wi-Fi" -RegistryKeyword "NetworkAddress" -RegistryValue $newmac -RegistryDataType REG_SZ
Remove-NetAdapterAdvancedProperty -Name "Wi-Fi 2" -RegistryKeyword "NetworkAddress" -AllProperties
New-NetAdapterAdvancedProperty -Name "Wi-Fi 2" -RegistryKeyword "NetworkAddress" -RegistryValue $newmac -RegistryDataType REG_SZ
Remove-NetAdapterAdvancedProperty -Name "Wi-Fi 3" -RegistryKeyword "NetworkAddress" -AllProperties
New-NetAdapterAdvancedProperty -Name "Wi-Fi 3" -RegistryKeyword "NetworkAddress" -RegistryValue $newmac -RegistryDataType REG_SZ