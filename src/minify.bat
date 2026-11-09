@echo off
rem Builds shader.h (const char *intro_glsl) from intro.glsl for the Release build.
rem First bakes the config.h values into a copy of the shader (baked\intro.glsl).
rem Uses Shader Minifier when tools\shader_minifier.exe exists, otherwise embeds the
rem source with comments stripped so the build still works.
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File bake_config.ps1
if errorlevel 1 exit /b 1
set MINIFIER=..\tools\shader_minifier.exe
rem --aggressive-inlining: every constant is written where it is used, which Crinkler compresses
rem better: 30 bytes less, same values, same code
rem --field-names rgba: swizzles written .rgba instead of .xyzw, which Crinkler compresses better
rem (about 25 bytes less; the same components, the same code)
if exist "%MINIFIER%" (
	"%MINIFIER%" baked\intro.glsl --format c-variables --aggressive-inlining --field-names rgba -o shader.h
) else (
	echo minify.bat: tools\shader_minifier.exe not found, embedding the unminified shader
	powershell -NoProfile -ExecutionPolicy Bypass -File embed_shader.ps1
)
exit /b %errorlevel%
