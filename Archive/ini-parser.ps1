# PowerShell equivalent of ini-parser.sh
# Simple INI parser function

function Parse-IniFile {
    param([string]$filePath)

    $ini = @{}
    $section = "default"
    $ini[$section] = @{}

    Get-Content $filePath | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\[(.+)\]$') {
            $section = $matches[1]
            if (-not $ini.ContainsKey($section)) {
                $ini[$section] = @{}
            }
        } elseif ($line -match '^(.+?)\s*=\s*(.+)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            $ini[$section][$key] = $value
        }
    }
    return $ini
}

function get_value {
    param([string]$section, [string]$key)
    return $global:iniConfig[$section][$key]
}

# To use: $global:iniConfig = Parse-IniFile 'path\to\file'
