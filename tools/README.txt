Drop the 32-bit tools here:

  link.exe              = crinkler.exe renamed (https://github.com/runestubbe/Crinkler)
                          The Release config puts this folder first in the executable path,
                          so Visual Studio links through Crinkler (enabled by /CRINKLER).
  shader_minifier.exe   https://github.com/laurentlb/Shader_Minifier
                          Used by src/minify.bat; without it the shader is embedded unminified.
