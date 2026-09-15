# Onyx : rend le décodage matériel sans copie possible dans la texture Flutter.
#
# mpv garde une image décodée par Direct3D 11 sur le GPU grâce à son interop
# « d3d11-egl » : ANGLE (le moteur OpenGL ES de media_kit) reçoit la texture du
# décodeur par un flux EGL, sans jamais la faire passer par la mémoire vive.
# Son initialisation exige que l'affichage EGL déclare EGL_EXT_device_query. Or
# ANGLE la déclare depuis longtemps comme extension *client* (sur EGL_NO_DISPLAY),
# pas d'affichage : la vérification échoue, l'interop n'est jamais chargée, et
# mpv décode en d3d11va-copy — chaque image 4K recopiée vers le processeur puis
# renvoyée au GPU. Le reste de ce qu'il demande est là et fonctionne (vérifié sur
# l'ANGLE livré ici : partage de textures, flux, périphérique D3D11 avec décodage
# vidéo et HEVC Main10). La vérification est identique dans mpv 0.41.
#
# Le correctif remplace, dans le binaire, le nom exigé par EGL_KHR_stream : une
# extension d'affichage qu'ANGLE déclare bien, et dont l'interop se sert de toute
# façon. La chaîne n'apparaît qu'une fois dans libmpv ; la longueur est gardée et
# le reste complété par des zéros. Si l'interrogation du périphérique échouait
# malgré tout, mpv le signale et retombe sur la copie, comme avant.
#
# Voir docs/adr/0019-decodage-sans-copie-sous-windows.md.

param(
  [Parameter(Mandatory = $true)][string]$Source,
  [Parameter(Mandatory = $true)][string]$Destination,
  [Parameter(Mandatory = $true)][string]$ExpectedSourceMd5,
  [Parameter(Mandatory = $true)][string]$ExpectedPatchedMd5
)

$ErrorActionPreference = 'Stop'

function Get-Md5([byte[]]$bytes) {
  $md5 = [System.Security.Cryptography.MD5]::Create()
  try {
    return ([System.BitConverter]::ToString($md5.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
  } finally {
    $md5.Dispose()
  }
}

$bytes = [System.IO.File]::ReadAllBytes($Source)
$sourceMd5 = Get-Md5 $bytes
if ($sourceMd5 -ne $ExpectedSourceMd5.ToLowerInvariant()) {
  throw "libmpv-2.dll inattendu (MD5 $sourceMd5) : le correctif est écrit pour une DLL précise."
}

# Latin-1 fait correspondre chaque octet à un caractère : la recherche et le
# remplacement se font sur le texte sans rien altérer du reste du binaire.
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$text = $latin1.GetString($bytes)

$needle = "EGL_EXT_device_query`0"
$replacement = "EGL_KHR_stream".PadRight($needle.Length, [char]0)

$first = $text.IndexOf($needle, [System.StringComparison]::Ordinal)
if ($first -lt 0) { throw "Chaîne EGL_EXT_device_query introuvable dans libmpv-2.dll." }
if ($text.IndexOf($needle, $first + 1, [System.StringComparison]::Ordinal) -ge 0) {
  throw "EGL_EXT_device_query apparaît plusieurs fois : correctif ambigu, abandon."
}

$patched = $latin1.GetBytes($text.Substring(0, $first) + $replacement + $text.Substring($first + $needle.Length))
$patchedMd5 = Get-Md5 $patched
if ($patchedMd5 -ne $ExpectedPatchedMd5.ToLowerInvariant()) {
  throw "Résultat inattendu après correctif (MD5 $patchedMd5)."
}

[System.IO.File]::WriteAllBytes($Destination, $patched)
Write-Output "libmpv-2.dll corrigée (d3d11-egl) : $patchedMd5"
