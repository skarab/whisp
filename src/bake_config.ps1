# Release build: writes baked\intro.glsl, a copy of intro.glsl with the config.h values in place
# of the _XX macros (main.cpp prepends them as #defines in Debug only). Shader Minifier then sees
# plain numbers it can fold, and the exe does not carry the defines string.
# _CM gets the camera plans of cameras.txt, as main.cpp does in Debug (PlanDefines()).
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# config.h: "#define NAME value // comment"
$defines = @{}
foreach ($line in Get-Content (Join-Path $root 'config.h')) {
    if ($line -match '^\s*#define\s+(\w+)\s+(.+?)\s*(//.*)?$') {
        $defines[$Matches[1]] = $Matches[2]
    }
}

function Get-ConfigValue([string]$name) {
    if (-not $defines.ContainsKey($name)) {
        throw "bake_config.ps1: $name is not defined in config.h"
    }
    $value = $defines[$name]
    # Expand the other config names (BRICK_COUNT = TEXTURE_SIZE / BRICK_SIZE), then fold the arithmetic
    for ($pass = 0; $pass -lt 4; $pass++) {
        foreach ($other in $defines.Keys) {
            if ($other -ne $name) {
                $value = $value -replace "\b$other\b", $defines[$other]
            }
        }
    }
    if ($value -match '[+*/]|\d\s*-') {
        $value = [string](Invoke-Expression $value)
    }
    return $value.Trim()
}

# Same values as the shaderHeader of main.cpp (Debug)
$macros = [ordered]@{
    '_XR' = (Get-ConfigValue 'XRES') + '.'
    '_YR' = (Get-ConfigValue 'YRES') + '.'
    '_NS' = Get-ConfigValue 'NOISE_SIZE'
    '_TS' = Get-ConfigValue 'TEXTURE_SIZE'
    '_BS' = Get-ConfigValue 'BRICK_SIZE'
    '_BC' = Get-ConfigValue 'BRICK_COUNT'
    '_LS' = Get-ConfigValue 'LIGHT_SIZE'
    '_Q'  = Get-ConfigValue 'STEP_SCALE'
    '_GS' = Get-ConfigValue 'GODRAY_SAMPLES'
    '_RS' = Get-ConfigValue 'RENDER_SCALE'
    '_SR' = Get-ConfigValue 'SAMPLE_RATE'
    '_AW' = Get-ConfigValue 'AUDIO_WIDTH'
    '_AB' = Get-ConfigValue 'AUDIO_BLOCK'
    '_AU' = Get-ConfigValue 'AUDIO_WARMUP'
    '_DU' = Get-ConfigValue 'DURATION'
    '_SD' = Get-ConfigValue 'SHOT_DURATION'
    '_SC' = Get-ConfigValue 'SHOT_COUNT'
    '_PR' = Get-ConfigValue 'PROLOGUE'
}

# Camera plans: per plan the start view and the end view (the start view for a static plan),
# x y z yaw pitch in hundredths. A plan without a view holds the last view of the plan before it;
# without any view, a view of the box from the side.
$shotCount = [int](Get-ConfigValue 'SHOT_COUNT')
$views = @{}
$cameraFile = Join-Path $root 'cameras.txt'
if (Test-Path $cameraFile) {
    foreach ($line in Get-Content $cameraFile) {
        if ($line -match '^plan (\d+) (start|end) position=vec3\(([^,]+), ([^,]+), ([^)]+)\) forward=vec3\([^)]*\) yaw=(\S+) pitch=(\S+)') {
            # PowerShell casts parse with the invariant culture (a dot, whatever the Windows locale)
            $views["$($Matches[1]) $($Matches[2])"] = @($Matches[3], $Matches[4], $Matches[5], $Matches[6], $Matches[7]) | ForEach-Object { [int][math]::Floor([double]$_ * 100 + 0.5) }
        }
    }
} else {
    Write-Host "bake_config.ps1: no cameras.txt, the camera stays on the default view"
}
$last = @(50, 15, 200, 314, 20)
$plans = @()
for ($plan = 0; $plan -lt $shotCount; $plan++) {
    $start = $views["$plan start"]
    if (-not $start) {
        Write-Host "bake_config.ps1: plan $plan has no view, it holds the view before"
        $start = $last
    }
    $end = $views["$plan end"]
    if (-not $end) { $end = $start }
    $plans += $start + $end
    $last = $end
}
$macros['_CM'] = $plans -join ','

$source = Get-Content (Join-Path $root 'intro.glsl') -Raw
foreach ($macro in $macros.Keys) {
    $source = $source -replace "\b$macro\b", $macros[$macro]
}
# float(10) -> 10. : the integer config values read as floats (float(_SD), float(_PR)...). Shader
# Minifier keeps float(10) as it is, but folds 10. into the constant expressions around it (-30 bytes).
$source = $source -replace 'float\((\d+)\)', '$1.'
# The Debug free camera hook _C(position, forward) is empty in Release: remove its call, so the
# Release glues of main.cpp need no #define _C
$source = $source -replace '(?m)^[ \t]*_C\([^)\r\n]*\);[^\r\n]*\r?\n', ''

$directory = Join-Path $root 'baked'
New-Item -ItemType Directory -Force -Path $directory | Out-Null
Set-Content -Path (Join-Path $directory 'intro.glsl') -Value $source -Encoding Ascii -NoNewline
foreach ($macro in $macros.Keys) {
    Write-Host ("bake_config.ps1: {0} = {1}" -f $macro, $macros[$macro])
}
