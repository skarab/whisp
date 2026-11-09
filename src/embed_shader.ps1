# Fallback when Shader Minifier is not available: baked\intro.glsl (intro.glsl with the config
# values and the camera plans, bake_config.ps1) -> shader.h as a C string, line comments and
# blank lines removed. Same variable name as Shader Minifier output.
$src = Join-Path $PSScriptRoot 'baked\intro.glsl'
$dst = Join-Path $PSScriptRoot 'shader.h'
$out = New-Object System.Collections.Generic.List[string]
$out.Add('const char *intro_glsl =')
foreach ($line in Get-Content $src) {
    $line = ($line -replace '//.*$', '').Trim()
    if ($line.Length -eq 0) { continue }
    $out.Add('"' + $line.Replace('\', '\\').Replace('"', '\"') + '\n"')
}
$out[$out.Count - 1] += ';'
Set-Content -Path $dst -Value $out -Encoding Ascii
