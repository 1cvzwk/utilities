```powershell
#requires -Version 5.1
<#
.SYNOPSIS
    Universal TXT/File Encoder, Decoder, Hash Generator and Compact Binary Compressor.

.DESCRIPTION
    Converts files into:
      1. HEX
      2. BINARY (0/1)
      3. BIT representation
      4. BYTE representation
      5. BASE16
      6. BASE32
      7. BASE64
      8. SHA-256
      9. SHA-384
     10. SHA-512
     11. SHA-1
     12. MD5
     13. Compact Binary / DEFLATE

    Reversible:
      HEX       -> original bytes
      BINARY    -> original bytes
      BIT       -> original bytes
      BYTE      -> original bytes
      BASE16    -> original bytes
      BASE32    -> original bytes
      BASE64    -> original bytes
      COMPACT   -> original bytes

    NOT reversible:
      SHA-256
      SHA-384
      SHA-512
      SHA-1
      MD5

.NOTES
    The script operates on raw bytes, so it can safely preserve UTF-8,
    UTF-16, ANSI, and binary data.

    "Compact Binary" uses DEFLATE compression. It does not convert
    arbitrary data into mathematically fewer bits without compression;
    compression is effective only when the data contains redundancy.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

$ScriptVersion = "1.0"

$OutputDirectory = Join-Path (Get-Location) "Converted"

if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
}

# ------------------------------------------------------------
# Utility
# ------------------------------------------------------------

function Pause-Script {
    Write-Host ""
    Read-Host "Press ENTER to continue"
}

function Get-InputFile {
    param(
        [string]$Prompt = "Enter input file path"
    )

    Write-Host ""
    $path = Read-Host $Prompt

    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "No file path supplied."
    }

    $path = $path.Trim('"')

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "File not found: $path"
    }

    return (Resolve-Path -LiteralPath $path).Path
}

function Get-OutputPath {
    param(
        [string]$InputPath,
        [string]$Extension
    )

    $name = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)

    return Join-Path $OutputDirectory "$name.$Extension"
}

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Text
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Text,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-FileBytes {
    param([string]$Path)

    return [System.IO.File]::ReadAllBytes($Path)
}

function Write-Bytes {
    param(
        [string]$Path,
        [byte[]]$Bytes
    )

    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

# ------------------------------------------------------------
# Header system
# ------------------------------------------------------------

function New-Header {
    param(
        [string]$Format,
        [string]$OriginalName
    )

    $safeName = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($OriginalName)
    )

    return @(
        "PS-UNIVERSAL-CONVERTER"
        "VERSION=$ScriptVersion"
        "FORMAT=$Format"
        "ORIGINAL_NAME_B64=$safeName"
        "DATA_BEGIN"
    ) -join "`n"
}

function Split-EncodedFile {
    param(
        [string]$Path
    )

    $text = [System.IO.File]::ReadAllText(
        $Path,
        [Text.Encoding]::UTF8
    )

    $marker = "DATA_BEGIN`n"

    $index = $text.IndexOf($marker)

    if ($index -lt 0) {
        throw "Invalid converter file: DATA_BEGIN header was not found."
    }

    $header = $text.Substring(0, $index)
    $data = $text.Substring($index + $marker.Length)

    $format = $null
    $originalName = "decoded.bin"

    foreach ($line in ($header -split "`n")) {

        if ($line -like "FORMAT=*") {
            $format = $line.Substring(7)
        }

        if ($line -like "ORIGINAL_NAME_B64=*") {

            $encodedName = $line.Substring(18)

            try {
                $originalName = [Text.Encoding]::UTF8.GetString(
                    [Convert]::FromBase64String($encodedName)
                )
            }
            catch {
                $originalName = "decoded.bin"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($format)) {
        throw "Could not determine encoded format."
    }

    return @{
        Format       = $format
        OriginalName = $originalName
        Data         = $data.Trim()
    }
}

# ------------------------------------------------------------
# HEX
# ------------------------------------------------------------

function Convert-ToHex {
    param([byte[]]$Bytes)

    return ([BitConverter]::ToString($Bytes)).Replace("-", "")
}

function Convert-FromHex {
    param([string]$Hex)

    $Hex = $Hex -replace "\s", ""

    if (($Hex.Length % 2) -ne 0) {
        throw "HEX data must contain an even number of characters."
    }

    $result = [byte[]]::new($Hex.Length / 2)

    for ($i = 0; $i -lt $Hex.Length; $i += 2) {

        $result[$i / 2] = [Convert]::ToByte(
            $Hex.Substring($i, 2),
            16
        )
    }

    return $result
}

# ------------------------------------------------------------
# BINARY / BIT
# ------------------------------------------------------------

function Convert-ToBinary {
    param([byte[]]$Bytes)

    $sb = [Text.StringBuilder]::new()

    foreach ($b in $Bytes) {
        [void]$sb.Append(
            [Convert]::ToString($b, 2).PadLeft(8, "0")
        )
    }

    return $sb.ToString()
}

function Convert-FromBinary {
    param([string]$Binary)

    $Binary = $Binary -replace "\s", ""

    if (($Binary.Length % 8) -ne 0) {
        throw "Binary data must contain a multiple of 8 bits."
    }

    $result = [byte[]]::new($Binary.Length / 8)

    for ($i = 0; $i -lt $Binary.Length; $i += 8) {

        $part = $Binary.Substring($i, 8)

        if ($part -notmatch "^[01]{8}$") {
            throw "Invalid binary byte: $part"
        }

        $result[$i / 8] = [Convert]::ToByte($part, 2)
    }

    return $result
}

function Convert-ToBitText {
    param([byte[]]$Bytes)

    $sb = [Text.StringBuilder]::new()

    foreach ($b in $Bytes) {

        for ($i = 7; $i -ge 0; $i--) {

            $bit = ($b -shr $i) -band 1

            [void]$sb.Append($bit)

            if ($i -gt 0) {
                [void]$sb.Append(" ")
            }
        }

        [void]$sb.AppendLine()
    }

    return $sb.ToString()
}

function Convert-FromBitText {
    param([string]$Text)

    $bits = $Text -replace "[^01]", ""

    return Convert-FromBinary $bits
}

# ------------------------------------------------------------
# BYTE representation
# ------------------------------------------------------------

function Convert-ToByteText {
    param([byte[]]$Bytes)

    return (($Bytes | ForEach-Object { $_.ToString() }) -join " ")
}

function Convert-FromByteText {
    param([string]$Text)

    $tokens = $Text -split "\s+" | Where-Object {
        $_ -ne ""
    }

    $result = [byte[]]::new($tokens.Count)

    for ($i = 0; $i -lt $tokens.Count; $i++) {

        $value = 0

        if (-not [int]::TryParse(
            $tokens[$i],
            [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$value
        )) {
            throw "Invalid byte value: $($tokens[$i])"
        }

        if ($value -lt 0 -or $value -gt 255) {
            throw "Byte value outside 0-255: $value"
        }

        $result[$i] = [byte]$value
    }

    return $result
}

# ------------------------------------------------------------
# BASE16
# ------------------------------------------------------------

function Convert-ToBase16 {
    param([byte[]]$Bytes)

    return Convert-ToHex $Bytes
}

function Convert-FromBase16 {
    param([string]$Text)

    return Convert-FromHex $Text
}

# ------------------------------------------------------------
# BASE64
# ------------------------------------------------------------

function Convert-ToBase64 {
    param([byte[]]$Bytes)

    return [Convert]::ToBase64String($Bytes)
}

function Convert-FromBase64 {
    param([string]$Text)

    try {
        return [Convert]::FromBase64String(
            ($Text -replace "\s", "")
        )
    }
    catch {
        throw "Invalid Base64 data."
    }
}

# ------------------------------------------------------------
# BASE32
# ------------------------------------------------------------

$Base32Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

function Convert-ToBase32 {
    param([byte[]]$Bytes)

    if ($Bytes.Length -eq 0) {
        return ""
    }

    $bits = New-Object System.Collections.Generic.List[int]

    foreach ($b in $Bytes) {

        for ($i = 7; $i -ge 0; $i--) {
            $bits.Add(($b -shr $i) -band 1)
        }
    }

    $sb = [Text.StringBuilder]::new()

    for ($i = 0; $i -lt $bits.Count; $i += 5) {

        $value = 0

        for ($j = 0; $j -lt 5; $j++) {

            $value = $value -shl 1

            if (($i + $j) -lt $bits.Count) {
                $value += $bits[$i + $j]
            }
        }

        [void]$sb.Append($Base32Alphabet[$value])
    }

    while (($sb.Length % 8) -ne 0) {
        [void]$sb.Append("=")
    }

    return $sb.ToString()
}

function Convert-FromBase32 {
    param([string]$Text)

    $Text = ($Text -replace "\s", "").ToUpperInvariant()
    $Text = $Text.TrimEnd("=")

    $bits = New-Object System.Collections.Generic.List[int]

    foreach ($char in $Text.ToCharArray()) {

        $index = $Base32Alphabet.IndexOf($char)

        if ($index -lt 0) {
            throw "Invalid Base32 character: $char"
        }

        for ($i = 4; $i -ge 0; $i--) {
            $bits.Add(($index -shr $i) -band 1)
        }
    }

    $byteCount = [Math]::Floor($bits.Count / 8)

    $result = [byte[]]::new([int]$byteCount)

    for ($i = 0; $i -lt $byteCount; $i++) {

        $value = 0

        for ($j = 0; $j -lt 8; $j++) {

            $value = ($value -shl 1) + $bits[
                ($i * 8) + $j
            ]
        }

        $result[$i] = [byte]$value
    }

    return $result
}

# ------------------------------------------------------------
# HASHES
# ------------------------------------------------------------

function Get-HashText {
    param(
        [byte[]]$Bytes,
        [string]$Algorithm
    )

    $hashAlgorithm = switch ($Algorithm.ToUpperInvariant()) {

        "MD5"    { [Security.Cryptography.MD5]::Create() }
        "SHA1"   { [Security.Cryptography.SHA1]::Create() }
        "SHA256" { [Security.Cryptography.SHA256]::Create() }
        "SHA384" { [Security.Cryptography.SHA384]::Create() }
        "SHA512" { [Security.Cryptography.SHA512]::Create() }

        default {
            throw "Unsupported hash algorithm."
        }
    }

    try {
        $hash = $hashAlgorithm.ComputeHash($Bytes)

        return ([BitConverter]::ToString($hash)).Replace("-", "")
    }
    finally {
        $hashAlgorithm.Dispose()
    }
}

# ------------------------------------------------------------
# COMPACT BINARY / DEFLATE
# ------------------------------------------------------------

function Compress-Bytes {
    param([byte[]]$Bytes)

    $output = [IO.MemoryStream]::new()

    try {

        $deflate = [IO.Compression.DeflateStream]::new(
            $output,
            [IO.Compression.CompressionMode]::Compress,
            $true
        )

        try {
            $deflate.Write($Bytes, 0, $Bytes.Length)
        }
        finally {
            $deflate.Dispose()
        }

        return $output.ToArray()
    }
    finally {
        $output.Dispose()
    }
}

function Decompress-Bytes {
    param([byte[]]$Bytes)

    $input = [IO.MemoryStream]::new($Bytes)
    $output = [IO.MemoryStream]::new()

    try {

        $deflate = [IO.Compression.DeflateStream]::new(
            $input,
            [IO.Compression.CompressionMode]::Decompress
        )

        try {
            $deflate.CopyTo($output)
        }
        finally {
            $deflate.Dispose()
        }

        return $output.ToArray()
    }
    finally {
        $input.Dispose()
        $output.Dispose()
    }
}

# ------------------------------------------------------------
# ENCODING OPERATIONS
# ------------------------------------------------------------

function Encode-File {
    param(
        [string]$InputPath,
        [string]$Format
    )

    $bytes = Get-FileBytes $InputPath
    $originalName = [IO.Path]::GetFileName($InputPath)

    switch ($Format) {

        "HEX" {
            $data = Convert-ToHex $bytes
            $extension = "hex.txt"
        }

        "BINARY" {
            $data = Convert-ToBinary $bytes
            $extension = "binary.txt"
        }

        "BIT" {
            $data = Convert-ToBitText $bytes
            $extension = "bits.txt"
        }

        "BYTE" {
            $data = Convert-ToByteText $bytes
            $extension = "bytes.txt"
        }

        "BASE16" {
            $data = Convert-ToBase16 $bytes
            $extension = "base16.txt"
        }

        "BASE32" {
            $data = Convert-ToBase32 $bytes
            $extension = "base32.txt"
        }

        "BASE64" {
            $data = Convert-ToBase64 $bytes
            $extension = "base64.txt"
        }

        "COMPACT" {

            $compressed = Compress-Bytes $bytes

            $data = Convert-ToBase64 $compressed

            $extension = "compact.bin.txt"
        }

        default {
            throw "Unsupported encoding format: $Format"
        }
    }

    $header = New-Header $Format $originalName

    $output = Join-Path $OutputDirectory (
        [IO.Path]::GetFileNameWithoutExtension($InputPath) +
        "." +
        $extension
    )

    Write-TextFile $output "$header`n$data"

    Write-Host ""
    Write-Host "Conversion complete." -ForegroundColor Green
    Write-Host "Format : $Format"
    Write-Host "Input  : $InputPath"
    Write-Host "Output : $output"

    Write-Host ""
    Write-Host "Original bytes : $($bytes.Length)"

    if ($Format -eq "COMPACT") {

        Write-Host "Compressed bytes: $($compressed.Length)"

        if ($bytes.Length -gt 0) {

            $ratio = [Math]::Round(
                ($compressed.Length / $bytes.Length) * 100,
                2
            )

            Write-Host "Size ratio      : $ratio %"
        }
    }
}

# ------------------------------------------------------------
# DECODING OPERATIONS
# ------------------------------------------------------------

function Decode-File {
    param(
        [string]$InputPath
    )

    $parsed = Split-EncodedFile $InputPath

    $format = $parsed.Format
    $originalName = $parsed.OriginalName
    $data = $parsed.Data

    Write-Host ""
    Write-Host "Detected format: $format"
    Write-Host "Original name  : $originalName"

    switch ($format) {

        "HEX" {
            $bytes = Convert-FromHex $data
        }

        "BINARY" {
            $bytes = Convert-FromBinary $data
        }

        "BIT" {
            $bytes = Convert-FromBitText $data
        }

        "BYTE" {
            $bytes = Convert-FromByteText $data
        }

        "BASE16" {
            $bytes = Convert-FromBase16 $data
        }

        "BASE32" {
            $bytes = Convert-FromBase32 $data
        }

        "BASE64" {
            $bytes = Convert-FromBase64 $data
        }

        "COMPACT" {

            $compressed = Convert-FromBase64 $data

            $bytes = Decompress-Bytes $compressed
        }

        "MD5" {
            throw "MD5 is a one-way hash and cannot be decoded."
        }

        "SHA1" {
            throw "SHA-1 is a one-way hash and cannot be decoded."
        }

        "SHA256" {
            throw "SHA-256 is a one-way hash and cannot be decoded."
        }

        "SHA384" {
            throw "SHA-384 is a one-way hash and cannot be decoded."
        }

        "SHA512" {
            throw "SHA-512 is a one-way hash and cannot be decoded."
        }

        default {
            throw "Unknown format: $format"
        }
    }

    # Protect against path traversal in the stored name.
    $safeName = [IO.Path]::GetFileName($originalName)

    if ([string]::IsNullOrWhiteSpace($safeName)) {
        $safeName = "decoded.bin"
    }

    $output = Join-Path $OutputDirectory (
        "DECODED_" + $safeName
    )

    Write-Bytes $output $bytes

    Write-Host ""
    Write-Host "Decode complete." -ForegroundColor Green
    Write-Host "Output : $output"
    Write-Host "Bytes  : $($bytes.Length)"
}

# ------------------------------------------------------------
# HASH OPERATION
# ------------------------------------------------------------

function Hash-File {
    param(
        [string]$InputPath,
        [string]$Algorithm
    )

    $bytes = Get-FileBytes $InputPath

    $hash = Get-HashText $bytes $Algorithm

    $originalName = [IO.Path]::GetFileName($InputPath)

    $header = New-Header $Algorithm $originalName

    $output = Join-Path $OutputDirectory (
        [IO.Path]::GetFileNameWithoutExtension($InputPath) +
        ".$Algorithm.hash.txt"
    )

    Write-TextFile $output "$header`n$hash"

    Write-Host ""
    Write-Host "$Algorithm HASH" -ForegroundColor Cyan
    Write-Host ""
    Write-Host $hash
    Write-Host ""
    Write-Host "Saved to: $output"
    Write-Host ""
    Write-Host "NOTE: Hashes cannot be converted back into the original file."
}

# ------------------------------------------------------------
# HASH VERIFICATION
# ------------------------------------------------------------

function Verify-Hash {
    param(
        [string]$OriginalFile,
        [string]$HashFile
    )

    $parsed = Split-EncodedFile $HashFile

    $format = $parsed.Format
    $expected = $parsed.Data.ToUpperInvariant()

    if ($format -notin @(
        "MD5",
        "SHA1",
        "SHA256",
        "SHA384",
        "SHA512"
    )) {
        throw "The selected file does not contain a supported hash."
    }

    $bytes = Get-FileBytes $OriginalFile

    $actual = Get-HashText $bytes $format

    Write-Host ""
    Write-Host "Hash verification" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Algorithm : $format"
    Write-Host "Expected  : $expected"
    Write-Host "Actual    : $actual"
    Write-Host ""

    if ($actual -eq $expected) {

        Write-Host "RESULT: MATCH" -ForegroundColor Green

        return $true
    }
    else {

        Write-Host "RESULT: DIFFERENT" -ForegroundColor Red

        return $false
    }
}

# ------------------------------------------------------------
# MENU
# ------------------------------------------------------------

function Show-MainMenu {

    Clear-Host

    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "       UNIVERSAL FILE ENCODER / DECODER - PS1" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " INPUT  : TXT or any other file"
    Write-Host " OUTPUT : .\Converted"
    Write-Host ""

    Write-Host "ENCODING"
    Write-Host "----------------------------------------------------------"
    Write-Host " 1. HEX"
    Write-Host " 2. Binary (0/1)"
    Write-Host " 3. Bit representation"
    Write-Host " 4. Byte representation"
    Write-Host " 5. Base16"
    Write-Host " 6. Base32"
    Write-Host " 7. Base64"
    Write-Host ""
    Write-Host "COMPRESSION"
    Write-Host "----------------------------------------------------------"
    Write-Host " 8. Compact Binary / DEFLATE"
    Write-Host ""
    Write-Host "HASH"
    Write-Host "----------------------------------------------------------"
    Write-Host " 9. SHA-256"
    Write-Host "10. SHA-384"
    Write-Host "11. SHA-512"
    Write-Host "12. SHA-1"
    Write-Host "13. MD5"
    Write-Host ""
    Write-Host "DECODING"
    Write-Host "----------------------------------------------------------"
    Write-Host "14. Re-convert encoded file"
    Write-Host "15. Verify hash"
    Write-Host ""
    Write-Host "SYSTEM"
    Write-Host "----------------------------------------------------------"
    Write-Host " 0. Exit"
    Write-Host ""
}

# ------------------------------------------------------------
# MAIN LOOP
# ------------------------------------------------------------

while ($true) {

    Show-MainMenu

    $choice = Read-Host "Select option"

    try {

        switch ($choice) {

            "1" {

                $file = Get-InputFile

                Encode-File $file "HEX"

                Pause-Script
            }

            "2" {

                $file = Get-InputFile

                Encode-File $file "BINARY"

                Pause-Script
            }

            "3" {

                $file = Get-InputFile

                Encode-File $file "BIT"

                Pause-Script
            }

            "4" {

                $file = Get-InputFile

                Encode-File $file "BYTE"

                Pause-Script
            }

            "5" {

                $file = Get-InputFile

                Encode-File $file "BASE16"

                Pause-Script
            }

            "6" {

                $file = Get-InputFile

                Encode-File $file "BASE32"

                Pause-Script
            }

            "7" {

                $file = Get-InputFile

                Encode-File $file "BASE64"

                Pause-Script
            }

            "8" {

                $file = Get-InputFile

                Encode-File $file "COMPACT"

                Pause-Script
            }

            "9" {

                $file = Get-InputFile

                Hash-File $file "SHA256"

                Pause-Script
            }

            "10" {

                $file = Get-InputFile

                Hash-File $file "SHA384"

                Pause-Script
            }

            "11" {

                $file = Get-InputFile

                Hash-File $file "SHA512"

                Pause-Script
            }

            "12" {

                $file = Get-InputFile

                Hash-File $file "SHA1"

                Pause-Script
            }

            "13" {

                $file = Get-InputFile

                Hash-File $file "MD5"

                Pause-Script
            }

            "14" {

                $file = Get-InputFile "Enter encoded file to decode"

                Decode-File $file

                Pause-Script
            }

            "15" {

                $original = Get-InputFile "Enter ORIGINAL file"

                $hashFile = Get-InputFile "Enter HASH file"

                Verify-Hash $original $hashFile

                Pause-Script
            }

            "0" {

                Clear-Host

                Write-Host "Exiting..." -ForegroundColor Cyan

                break
            }

            default {

                Write-Host ""
                Write-Host "Invalid option." -ForegroundColor Yellow

                Pause-Script
            }
        }

    }
    catch {

        Write-Host ""
        Write-Host "ERROR:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red

        Pause-Script
    }
}
```
