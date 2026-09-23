<#
.SYNOPSIS
  Signe le ZIP Windows pour la mise a jour automatique (voir ADR-0030).

.DESCRIPTION
  onyx-updater.exe n'applique qu'un ZIP signe par cette cle : c'est ce qui
  empeche n'importe quel compte du poste de faire installer ses propres
  fichiers dans Program Files par le service de mise a jour.

  La signature voyage dans le commentaire du ZIP, que tous les outils ignorent :
  le meme fichier reste le ZIP portable qu'on decompresse a la main.

    commentaire = "ONYXSIG1" + longueur de la version (1 octet) + version
                  + signature ECDSA P-256 (r||s, 64 octets)
    signe       = SHA-256("onyx-update-v1`n" + version + "`n"
                          + hex(SHA-256(ZIP sans commentaire)))

  Signer (cle privee dans ONYX_UPDATE_SIGNING_KEY, PKCS#8 en base64) :
    .\sign-windows-update.ps1 -Zip out\Onyx-1.2.3-windows-portable.zip -Version 1.2.3

  Nouvelle cle (remplace la cle publique compilee dans onyx-updater.exe : les
  versions deja installees refuseront alors tout ce qui est signe par la
  nouvelle, a ne faire qu'en cas de fuite) :
    .\sign-windows-update.ps1 -NewKey -KeyOut C:\chemin\hors\du\depot.txt

  N'utilise que CngKey : tourne aussi bien sous Windows PowerShell 5.1 que sous
  pwsh 7 (runner GitHub).
#>
[CmdletBinding(DefaultParameterSetName = 'Sign')]
param(
  [Parameter(ParameterSetName = 'Sign', Mandatory = $true)]
  [string]$Zip,
  [Parameter(ParameterSetName = 'Sign', Mandatory = $true)]
  [string]$Version,
  [Parameter(ParameterSetName = 'NewKey', Mandatory = $true)]
  [switch]$NewKey,
  [Parameter(ParameterSetName = 'NewKey', Mandatory = $true)]
  [string]$KeyOut
)

$ErrorActionPreference = 'Stop'
foreach ($assembly in 'System.Core', 'System.Security.Cryptography.Cng') {
  try { Add-Type -AssemblyName $assembly } catch {}
}

$PublicKeyHeader = Join-Path $PSScriptRoot '..\app\windows\updater\update_public_key.h'

function Get-Sha256([byte[]]$Bytes, [int]$Count) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return $sha.ComputeHash($Bytes, 0, $Count) } finally { $sha.Dispose() }
}

function ConvertTo-Hex([byte[]]$Bytes) {
  return -join ($Bytes | ForEach-Object { $_.ToString('x2') })
}

if ($NewKey) {
  $params = New-Object System.Security.Cryptography.CngKeyCreationParameters
  $params.ExportPolicy = [System.Security.Cryptography.CngExportPolicies]::AllowPlaintextExport
  # [NullString] : un $null passe tel quel deviendrait "", et CNG creerait une
  # cle persistante nommee "" dans le magasin de l'utilisateur au lieu d'une
  # cle ephemere.
  $key = [System.Security.Cryptography.CngKey]::Create(
    [System.Security.Cryptography.CngAlgorithm]::ECDsaP256, [NullString]::Value, $params)
  $private = $key.Export([System.Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
  # BCRYPT_ECCKEY_BLOB (en-tete ECS1 + X + Y) : exactement ce que
  # BCryptImportKeyPair attend, le C++ l'importe tel quel.
  $public = $key.Export([System.Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)

  [System.IO.File]::WriteAllText($KeyOut, [Convert]::ToBase64String($private))

  $lines = for ($i = 0; $i -lt $public.Length; $i += 12) {
    $end = [Math]::Min($i + 12, $public.Length) - 1
    '    ' + (($public[$i..$end] | ForEach-Object { '0x{0:x2}' -f $_ }) -join ', ') + ','
  }
  $header = @(
    '// Genere par scripts/sign-windows-update.ps1 -NewKey : ne pas modifier a la main.'
    '// Cle publique ECDSA P-256 (BCRYPT_ECCKEY_BLOB) des mises a jour Windows.'
    '#pragma once'
    ''
    'static const unsigned char kUpdatePublicKey[] = {'
    $lines
    '};'
    ''
  ) -join "`n"
  [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($PublicKeyHeader), $header)

  Write-Host "Cle privee : $KeyOut (a copier dans le secret GitHub ONYX_UPDATE_SIGNING_KEY)"
  Write-Host "Cle publique : app\windows\updater\update_public_key.h"
  return
}

if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version invalide : '$Version' (X.Y.Z attendu)" }
$keyBase64 = $env:ONYX_UPDATE_SIGNING_KEY
if ([string]::IsNullOrWhiteSpace($keyBase64)) { throw 'ONYX_UPDATE_SIGNING_KEY absent.' }

$zipPath = (Resolve-Path $Zip).Path
[byte[]]$bytes = [System.IO.File]::ReadAllBytes($zipPath)

# Fin de repertoire central : 22 octets + commentaire, le dernier element du
# fichier. On la cherche depuis la fin, en exigeant que la longueur du
# commentaire tombe pile sur la fin du fichier.
$eocd = -1
for ($i = $bytes.Length - 22; $i -ge [Math]::Max(0, $bytes.Length - 22 - 65535); $i--) {
  if ($bytes[$i] -eq 0x50 -and $bytes[$i + 1] -eq 0x4b -and $bytes[$i + 2] -eq 0x05 -and $bytes[$i + 3] -eq 0x06) {
    $commentLength = [BitConverter]::ToUInt16($bytes, $i + 20)
    if ($i + 22 + $commentLength -eq $bytes.Length) { $eocd = $i; break }
  }
}
if ($eocd -lt 0) { throw "$zipPath n'est pas un ZIP lisible." }

# Un commentaire deja present (ZIP deja signe) est retire : on signe toujours
# le ZIP nu.
$bytes[$eocd + 20] = 0
$bytes[$eocd + 21] = 0
$unsignedLength = $eocd + 22

$zipHash = ConvertTo-Hex (Get-Sha256 $bytes $unsignedLength)
$message = [System.Text.Encoding]::UTF8.GetBytes("onyx-update-v1`n$Version`n$zipHash")
$messageHash = Get-Sha256 $message $message.Length

$key = [System.Security.Cryptography.CngKey]::Import(
  [Convert]::FromBase64String($keyBase64.Trim()),
  [System.Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
$ecdsa = New-Object System.Security.Cryptography.ECDsaCng($key)
[byte[]]$signature = $ecdsa.SignHash($messageHash)
if ($signature.Length -ne 64) { throw "Signature inattendue ($($signature.Length) octets)." }

$versionBytes = [System.Text.Encoding]::ASCII.GetBytes($Version)
$comment = New-Object System.Collections.Generic.List[byte]
$comment.AddRange([System.Text.Encoding]::ASCII.GetBytes('ONYXSIG1'))
$comment.Add([byte]$versionBytes.Length)
$comment.AddRange($versionBytes)
$comment.AddRange($signature)

$lengthBytes = [BitConverter]::GetBytes([uint16]$comment.Count)
$bytes[$eocd + 20] = $lengthBytes[0]
$bytes[$eocd + 21] = $lengthBytes[1]

$stream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Create)
try {
  $stream.Write($bytes, 0, $unsignedLength)
  $stream.Write($comment.ToArray(), 0, $comment.Count)
} finally {
  $stream.Dispose()
}
Write-Host "Signe : $zipPath (version $Version)"
