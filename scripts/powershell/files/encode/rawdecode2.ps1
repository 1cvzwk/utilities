
#requires -Version 5.1

<#
===========================================================================
 PS-UNIVERSAL-CONVERTER
 Version : 2.0
 Purpose : Byte-preserving universal text/binary converter

 IMPORTANT:
 This converter works on BYTES, not PowerShell strings.

 Therefore the original file bytes are preserved exactly:
     ANSI
     UTF-8
     UTF-8 BOM
     UTF-16 LE
     UTF-16 BE
     tabs
     spaces
     CR/LF
     LF
     CR
     blank lines
     Unicode
     extended characters
     control bytes
     arbitrary symbols

 The compressed representation contains the original bytes.

 Compression:
     System.IO.Compression.DeflateStream

 Encoding/container:
     Base64 / Hex / Binary / Byte / Hash representations

 Reverse conversion:
     representation -> bytes -> Deflate decompression -> original bytes

 The decompressed file is written directly as bytes.
 No automatic text decoding/re-encoding is performed.

 KEYBOARD FILE BROWSER:
     Up Arrow       = previous item
     Down Arrow     = next item
     Enter          = open directory / select file
     Backspace      = parent directory
     Escape         = cancel
     Home           = first item
     End            = last item
===========================================================================#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    $ScriptRoot = (Get-Location).Path
}

# -------------------------------------------------------------------------
# Utility
# -------------------------------------------------------------------------

function Write-Title {
    param([string]$Text)

    Clear-Host
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " PS-UNIVERSAL-CONVERTER" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor White
    Write-Host ""
}

function Read-Choice {
    param(
        [string]$Prompt = "Select option"
    )

    Write-Host ""
    Write-Host $Prompt -ForegroundColor Yellow
    return Read-Host
}

function Get-FileBytes {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # ReadAllBytes is intentional.
    # It prevents PowerShell from decoding/re-encoding the file.
    return [System.IO.File]::ReadAllBytes($Path)
}

function Write-FileBytes {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    # WriteAllBytes writes the exact byte sequence supplied.
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

# -------------------------------------------------------------------------
# DEFLATE
# -------------------------------------------------------------------------

function Compress-Bytes {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    $output = [IO.MemoryStream]::new()

    try {
        $deflate = [IO.Compression.DeflateStream]::new(
            $output,
            [IO.Compression.CompressionMode]::Compress,
            $true
        )

        try {
            if ($Bytes.Length -gt 0) {
                $deflate.Write($Bytes, 0, $Bytes.Length)
            }
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
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

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

# -------------------------------------------------------------------------
# BYTE <-> HEX
# -------------------------------------------------------------------------

function Convert-BytesToHex {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    if ($Bytes.Length -eq 0) {
        return ""
    }

    return ([BitConverter]::ToString($Bytes) -replace "-", "")
}

function Convert-HexToBytes {
    param(
        [Parameter(Mandatory)]
        [string]$Hex
    )

    # Permit spaces, tabs, line breaks and separators.
    $clean = $Hex -replace '[^0-9A-Fa-f]', ''

    if (($clean.Length % 2) -ne 0) {
        throw "Invalid hexadecimal data: number of hexadecimal digits must be even."
    }

    $result = [byte[]]::new($clean.Length / 2)

    for ($i = 0; $i -lt $clean.Length; $i += 2) {
        $result[$i / 2] = [Convert]::ToByte(
            $clean.Substring($i, 2),
            16
        )
    }

    return $result
}

# -------------------------------------------------------------------------
# BYTE <-> BINARY
# -------------------------------------------------------------------------

function Convert-BytesToBinary {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    $sb = [Text.StringBuilder]::new()

    foreach ($b in $Bytes) {
        [void]$sb.Append(
            [Convert]::ToString($b, 2).PadLeft(8, '0')
        )
    }

    return $sb.ToString()
}

function Convert-BinaryToBytes {
    param(
        [Parameter(Mandatory)]
        [string]$Binary
    )

    # Ignore whitespace so formatted binary is accepted.
    $clean = $Binary -replace '\s', ''

    if ($clean.Length -eq 0) {
        return [byte[]]::new(0)
    }

    if ($clean -notmatch '^[01]+$') {
        throw "Invalid binary data. Only 0 and 1 are allowed."
    }

    if (($clean.Length % 8) -ne 0) {
        throw "Invalid binary data: length must be a multiple of 8."
    }

    $result = [byte[]]::new($clean.Length / 8)

    for ($i = 0; $i -lt $clean.Length; $i += 8) {
        $result[$i / 8] = [Convert]::ToByte(
            $clean.Substring($i, 8),
            2
        )
    }

    return $result
}

# -------------------------------------------------------------------------
# BYTE LIST
# -------------------------------------------------------------------------

function Convert-BytesToByteList {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    return ($Bytes | ForEach-Object { $_.ToString() }) -join ' '
}

function Convert-ByteListToBytes {
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $parts = $Text -split '[,\s;]+'

    $list = [System.Collections.Generic.List[byte]]::new()

    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            continue
        }

        $value = 0

        if (-not [int]::TryParse($part, [ref]$value)) {
            throw "Invalid byte value: $part"
        }

        if ($value -lt 0 -or $value -gt 255) {
            throw "Byte value outside 0-255 range: $value"
        }

        $list.Add([byte]$value)
    }

    return $list.ToArray()
}

# -------------------------------------------------------------------------
# BYTE <-> BASE64
# -------------------------------------------------------------------------

function Convert-BytesToBase64 {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    return [Convert]::ToBase64String($Bytes)
}

function Convert-Base64ToBytes {
    param(
        [Parameter(Mandatory)]
        [string]$Base64
    )

    # Remove whitespace/newlines introduced by formatting.
    $clean = $Base64 -replace '\s', ''

    return [Convert]::FromBase64String($clean)
}

# -------------------------------------------------------------------------
# HASH
# -------------------------------------------------------------------------

function Get-ByteHash {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes,

        [string]$Algorithm = "SHA256"
    )

    $hashAlgorithm = [System.Security.Cryptography.HashAlgorithm]::Create(
        $Algorithm
    )

    if ($null -eq $hashAlgorithm) {
        throw "Unsupported hash algorithm: $Algorithm"
    }

    try {
        $hash = $hashAlgorithm.ComputeHash($Bytes)
        return ([BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $hashAlgorithm.Dispose()
    }
}

# -------------------------------------------------------------------------
# UNIVERSAL ENCODING
# -------------------------------------------------------------------------

function Encode-Bytes {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes,

        [Parameter(Mandatory)]
        [ValidateSet("BASE64","HEX","BINARY","BYTE")]
        [string]$Format
    )

    switch ($Format) {
        "BASE64" {
            return Convert-BytesToBase64 $Bytes
        }

        "HEX" {
            return Convert-BytesToHex $Bytes
        }

        "BINARY" {
            return Convert-BytesToBinary $Bytes
        }

        "BYTE" {
            return Convert-BytesToByteList $Bytes
        }
    }
}

function Decode-Bytes {
    param(
        [Parameter(Mandatory)]
        [string]$Data,

        [Parameter(Mandatory)]
        [ValidateSet("BASE64","HEX","BINARY","BYTE")]
        [string]$Format
    )

    switch ($Format) {
        "BASE64" {
            return Convert-Base64ToBytes $Data
        }

        "HEX" {
            return Convert-HexToBytes $Data
        }

        "BINARY" {
            return Convert-BinaryToBytes $Data
        }

        "BYTE" {
            return Convert-ByteListToBytes $Data
        }
    }
}

# -------------------------------------------------------------------------
# FILE CONVERSION
# -------------------------------------------------------------------------

function Convert-FileToRepresentation {
    param(
        [Parameter(Mandatory)]
        [string]$InputFile,

        [Parameter(Mandatory)]
        [ValidateSet("BASE64","HEX","BINARY","BYTE")]
        [string]$Format,

        [switch]$Compress
    )

    $originalBytes = Get-FileBytes $InputFile

    $originalSize = $originalBytes.Length

    if ($Compress) {
        $workingBytes = Compress-Bytes $originalBytes
    }
    else {
        $workingBytes = $originalBytes
    }

    $encoded = Encode-Bytes $workingBytes $Format

    $directory = Split-Path -Parent $InputFile
    $name = [IO.Path]::GetFileNameWithoutExtension($InputFile)

    if ($Compress) {
        $outputName = "$name.$($Format.ToLowerInvariant()).deflate.txt"
    }
    else {
        $outputName = "$name.$($Format.ToLowerInvariant()).txt"
    }

    $outputPath = Join-Path $directory $outputName

    # ASCII is sufficient for Base64/HEX/BINARY/BYTE representations.
    [IO.File]::WriteAllText(
        $outputPath,
        $encoded,
        [Text.Encoding]::ASCII
    )

    [PSCustomObject]@{
        InputFile       = $InputFile
        OutputFile      = $outputPath
        OriginalBytes   = $originalSize
        StoredBytes     = $workingBytes.Length
        Compression     = if ($Compress) { "DEFLATE" } else { "NONE" }
        Representation  = $Format
        OriginalSHA256  = Get-ByteHash $originalBytes "SHA256"
        StoredSHA256    = Get-ByteHash $workingBytes "SHA256"
    }
}

function Convert-RepresentationToOriginalFile {
    param(
        [Parameter(Mandatory)]
        [string]$InputFile,

        [Parameter(Mandatory)]
        [ValidateSet("BASE64","HEX","BINARY","BYTE")]
        [string]$Format,

        [Parameter(Mandatory)]
        [string]$OutputFile,

        [switch]$Compressed
    )

    # Read the encoded container as text.
    # This does NOT affect the original file because the original bytes
    # are represented by BASE64/HEX/BINARY/BYTE data.
    $encodedText = [IO.File]::ReadAllText(
        $InputFile,
        [Text.Encoding]::ASCII
    )

    $storedBytes = Decode-Bytes $encodedText $Format

    if ($Compressed) {
        $originalBytes = Decompress-Bytes $storedBytes
    }
    else {
        $originalBytes = $storedBytes
    }

    # CRITICAL:
    # Write the bytes directly.
    # Never use Set-Content, Out-File, or a text encoding here.
    Write-FileBytes $OutputFile $originalBytes

    return [PSCustomObject]@{
        InputFile       = $InputFile
        OutputFile      = $OutputFile
        StoredBytes     = $storedBytes.Length
        OriginalBytes   = $originalBytes.Length
        Compression     = if ($Compressed) { "DEFLATE" } else { "NONE" }
        Representation  = $Format
        OutputSHA256    = Get-ByteHash $originalBytes "SHA256"
    }
}

# -------------------------------------------------------------------------
# BYTE-PERFECT VERIFICATION
# -------------------------------------------------------------------------

function Compare-ByteArrays {
    param(
        [Parameter(Mandatory)]
        [byte[]]$A,

        [Parameter(Mandatory)]
        [byte[]]$B
    )

    if ($A.Length -ne $B.Length) {
        return $false
    }

    for ($i = 0; $i -lt $A.Length; $i++) {
        if ($A[$i] -ne $B[$i]) {
            return $false
        }
    }

    return $true
}

function Test-RoundTrip {
    param(
        [Parameter(Mandatory)]
        [string]$InputFile
    )

    $original = Get-FileBytes $InputFile
    $compressed = Compress-Bytes $original
    $restored = Decompress-Bytes $compressed

    $equal = Compare-ByteArrays $original $restored

    [PSCustomObject]@{
        File              = $InputFile
        OriginalSize      = $original.Length
        CompressedSize    = $compressed.Length
        RestoredSize      = $restored.Length
        BytePerfect       = $equal
        OriginalSHA256    = Get-ByteHash $original "SHA256"
        RestoredSHA256    = Get-ByteHash $restored "SHA256"
        Compression       = "DEFLATE"
    }
}

# -------------------------------------------------------------------------
# KEYBOARD FILE EXPLORER
# -------------------------------------------------------------------------

function Invoke-KeyboardFileExplorer {
    param(
        [string]$StartDirectory = $ScriptRoot
    )

    $currentDirectory = (Resolve-Path $StartDirectory).Path

    while ($true) {

        $directories = @(
            Get-ChildItem -LiteralPath $currentDirectory -Directory -Force -ErrorAction SilentlyContinue |
            Sort-Object Name
        )

        $files = @(
            Get-ChildItem -LiteralPath $currentDirectory -File -Force -ErrorAction SilentlyContinue |
            Sort-Object Name
        )

        $items = @()

        foreach ($dir in $directories) {
            $items += [PSCustomObject]@{
                Kind = "DIR"
                Name = $dir.Name
                Path = $dir.FullName
            }
        }

        foreach ($file in $files) {
            $items += [PSCustomObject]@{
                Kind = "FILE"
                Name = $file.Name
                Path = $file.FullName
            }
        }

        # Parent entry.
        $parent = Split-Path -Parent $currentDirectory

        $selected = 0

        while ($true) {

            Clear-Host

            Write-Host "============================================================" -ForegroundColor Cyan
            Write-Host " HERMES / PS-UNIVERSAL-CONVERTER FILE EXPLORER" -ForegroundColor Cyan
            Write-Host "============================================================" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "ROOT : $ScriptRoot" -ForegroundColor DarkGray
            Write-Host "PATH : $currentDirectory" -ForegroundColor Yellow
            Write-Host ""
            Write-Host " UP/DOWN = navigate    ENTER = open/select" -ForegroundColor Gray
            Write-Host " BACKSPACE = parent    HOME/END = jump" -ForegroundColor Gray
            Write-Host " ESC = cancel" -ForegroundColor Gray
            Write-Host ""

            $displayItems = @()

            if ($parent) {
                $displayItems += [PSCustomObject]@{
                    Kind = "PARENT"
                    Name = ".."
                    Path = $parent
                }
            }

            $displayItems += $items

            if ($displayItems.Count -eq 0) {
                Write-Host "(empty directory)" -ForegroundColor DarkGray
            }

            for ($i = 0; $i -lt $displayItems.Count; $i++) {

                $entry = $displayItems[$i]

                if ($i -eq $selected) {
                    Write-Host " > " -NoNewline -ForegroundColor Black
                    Write-Host $entry.Name -ForegroundColor Black -BackgroundColor Cyan
                }
                else {
                    if ($entry.Kind -eq "DIR" -or $entry.Kind -eq "PARENT") {
                        Write-Host "   [$($entry.Name)]" -ForegroundColor Cyan
                    }
                    else {
                        Write-Host "   $($entry.Name)" -ForegroundColor White
                    }
                }
            }

            $key = [Console]::ReadKey($true)

            switch ($key.Key) {

                "UpArrow" {
                    if ($displayItems.Count -gt 0) {
                        $selected--

                        if ($selected -lt 0) {
                            $selected = $displayItems.Count - 1
                        }
                    }
                }

                "DownArrow" {
                    if ($displayItems.Count -gt 0) {
                        $selected++

                        if ($selected -ge $displayItems.Count) {
                            $selected = 0
                        }
                    }
                }

                "Home" {
                    $selected = 0
                }

                "End" {
                    if ($displayItems.Count -gt 0) {
                        $selected = $displayItems.Count - 1
                    }
                }

                "Backspace" {
                    if ($parent) {
                        $currentDirectory = $parent
                        break
                    }
                }

                "Escape" {
                    return $null
                }

                "Enter" {

                    if ($displayItems.Count -eq 0) {
                        continue
                    }

                    $chosen = $displayItems[$selected]

                    if ($chosen.Kind -eq "DIR") {
                        $currentDirectory = $chosen.Path
                        break
                    }

                    if ($chosen.Kind -eq "PARENT") {
                        $currentDirectory = $chosen.Path
                        break
                    }

                    if ($chosen.Kind -eq "FILE") {
                        return $chosen.Path
                    }
                }
            }
        }
    }
}

# -------------------------------------------------------------------------
# FILE SELECTION
# -------------------------------------------------------------------------

function Select-File {
    param(
        [string]$Description = "Select file"
    )

    Write-Title $Description

    Write-Host "Keyboard file explorer" -ForegroundColor Cyan
    Write-Host "Starting directory:" -NoNewline
    Write-Host " $ScriptRoot" -ForegroundColor Yellow
    Write-Host ""

    return Invoke-KeyboardFileExplorer -StartDirectory $ScriptRoot
}

# -------------------------------------------------------------------------
# CONVERSION MENU
# -------------------------------------------------------------------------

function Show-ConvertMenu {

    while ($true) {

        Write-Title "FILE → REPRESENTATION"

        Write-Host "1. BASE64"
        Write-Host "2. HEX"
        Write-Host "3. BINARY / BITS"
        Write-Host "4. BYTE LIST"
        Write-Host "5. BASE64 + DEFLATE"
        Write-Host "6. HEX + DEFLATE"
        Write-Host "7. BINARY + DEFLATE"
        Write-Host "8. BYTE LIST + DEFLATE"
        Write-Host "9. Back"
        Write-Host ""

        $choice = Read-Choice

        if ($choice -eq "9") {
            return
        }

        $format = $null
        $compress = $false

        switch ($choice) {
            "1" { $format = "BASE64" }
            "2" { $format = "HEX" }
            "3" { $format = "BINARY" }
            "4" { $format = "BYTE" }

            "5" {
                $format = "BASE64"
                $compress = $true
            }

            "6" {
                $format = "HEX"
                $compress = $true
            }

            "7" {
                $format = "BINARY"
                $compress = $true
            }

            "8" {
                $format = "BYTE"
                $compress = $true
            }

            default {
                Write-Host "Invalid option." -ForegroundColor Red
                Start-Sleep -Milliseconds 700
                continue
            }
        }

        $inputFile = Select-File "Select source file"

        if (-not $inputFile) {
            continue
        }

        try {

            $result = Convert-FileToRepresentation `
                -InputFile $inputFile `
                -Format $format `
                -Compress:$compress

            Write-Host ""
            Write-Host "Conversion completed." -ForegroundColor Green
            Write-Host ""
            Write-Host "Input       : $($result.InputFile)"
            Write-Host "Output      : $($result.OutputFile)"
            Write-Host "Original    : $($result.OriginalBytes) bytes"
            Write-Host "Stored      : $($result.StoredBytes) bytes"
            Write-Host "Compression : $($result.Compression)"
            Write-Host "Format      : $($result.Representation)"
            Write-Host "SHA256      : $($result.OriginalSHA256)"
            Write-Host ""

            Read-Host "Press ENTER"
        }
        catch {
            Write-Host ""
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ""
            Read-Host "Press ENTER"
        }
    }
}

# -------------------------------------------------------------------------
# REVERSE CONVERSION MENU
# -------------------------------------------------------------------------

function Show-ReverseMenu {

    while ($true) {

        Write-Title "REPRESENTATION → ORIGINAL FILE"

        Write-Host "1. BASE64 → original bytes"
        Write-Host "2. HEX → original bytes"
        Write-Host "3. BINARY → original bytes"
        Write-Host "4. BYTE LIST → original bytes"
        Write-Host "5. BASE64 + DEFLATE → original"
        Write-Host "6. HEX + DEFLATE → original"
        Write-Host "7. BINARY + DEFLATE → original"
        Write-Host "8. BYTE LIST + DEFLATE → original"
        Write-Host "9. Back"
        Write-Host ""

        $choice = Read-Choice

        if ($choice -eq "9") {
            return
        }

        $format = $null
        $compressed = $false

        switch ($choice) {
            "1" { $format = "BASE64" }
            "2" { $format = "HEX" }
            "3" { $format = "BINARY" }
            "4" { $format = "BYTE" }

            "5" {
                $format = "BASE64"
                $compressed = $true
            }

            "6" {
                $format = "HEX"
                $compressed = $true
            }

            "7" {
                $format = "BINARY"
                $compressed = $true
            }

            "8" {
                $format = "BYTE"
                $compressed = $true
            }

            default {
                Write-Host "Invalid option." -ForegroundColor Red
                Start-Sleep -Milliseconds 700
                continue
            }
        }

        $inputFile = Select-File "Select encoded file"

        if (-not $inputFile) {
            continue
        }

        $defaultName = [IO.Path]::GetFileNameWithoutExtension($inputFile)

        if ($defaultName.EndsWith(".deflate")) {
            $defaultName = $defaultName.Substring(
                0,
                $defaultName.Length - ".deflate".Length
            )
        }

        $outputFile = Join-Path `
            (Split-Path -Parent $inputFile) `
            "$defaultName.restored"

        Write-Host ""
        Write-Host "Default output:" -ForegroundColor Yellow
        Write-Host $outputFile
        Write-Host ""

        $customOutput = Read-Host "Output path (ENTER = default)"

        if (-not [string]::IsNullOrWhiteSpace($customOutput)) {
            $outputFile = $customOutput
        }

        try {

            $result = Convert-RepresentationToOriginalFile `
                -InputFile $inputFile `
                -Format $format `
                -OutputFile $outputFile `
                -Compressed:$compressed

            Write-Host ""
            Write-Host "Decompression/reconstruction completed." -ForegroundColor Green
            Write-Host ""
            Write-Host "Input       : $($result.InputFile)"
            Write-Host "Output      : $($result.OutputFile)"
            Write-Host "Stored      : $($result.StoredBytes) bytes"
            Write-Host "Original    : $($result.OriginalBytes) bytes"
            Write-Host "Compression : $($result.Compression)"
            Write-Host "Format      : $($result.Representation)"
            Write-Host "SHA256      : $($result.OutputSHA256)"
            Write-Host ""

            Read-Host "Press ENTER"
        }
        catch {
            Write-Host ""
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ""
            Read-Host "Press ENTER"
        }
    }
}

# -------------------------------------------------------------------------
# ROUND-TRIP VERIFICATION
# -------------------------------------------------------------------------

function Show-RoundTripTest {

    Write-Title "BYTE-PERFECT ROUND-TRIP TEST"

    $inputFile = Select-File "Select file to test"

    if (-not $inputFile) {
        return
    }

    try {

        $result = Test-RoundTrip $inputFile

        Write-Host ""
        Write-Host "Original size : $($result.OriginalSize) bytes"
        Write-Host "Compressed    : $($result.CompressedSize) bytes"
        Write-Host "Restored      : $($result.RestoredSize) bytes"
        Write-Host ""
        Write-Host "Compression   : $($result.Compression)"
        Write-Host "Original SHA  : $($result.OriginalSHA256)"
        Write-Host "Restored SHA  : $($result.RestoredSHA256)"
        Write-Host ""

        if ($result.BytePerfect) {
            Write-Host "RESULT: BYTE-PERFECT" -ForegroundColor Green
            Write-Host "The decompressed bytes are identical to the original bytes." -ForegroundColor Green
        }
        else {
            Write-Host "RESULT: MISMATCH" -ForegroundColor Red
        }

        Write-Host ""
        Read-Host "Press ENTER"
    }
    catch {
        Write-Host ""
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Read-Host "Press ENTER"
    }
}

# -------------------------------------------------------------------------
# HASH MENU
# -------------------------------------------------------------------------

function Show-HashMenu {

    while ($true) {

        Write-Title "FILE HASH"

        Write-Host "1. SHA256"
        Write-Host "2. SHA1"
        Write-Host "3. MD5"
        Write-Host "4. Back"
        Write-Host ""

        $choice = Read-Choice

        if ($choice -eq "4") {
            return
        }

        $algorithm = switch ($choice) {
            "1" { "SHA256" }
            "2" { "SHA1" }
            "3" { "MD5" }
            default { $null }
        }

        if (-not $algorithm) {
            continue
        }

        $inputFile = Select-File "Select file for hashing"

        if (-not $inputFile) {
            continue
        }

        try {

            $bytes = Get-FileBytes $inputFile
            $hash = Get-ByteHash $bytes $algorithm

            Write-Host ""
            Write-Host "File      : $inputFile"
            Write-Host "Algorithm : $algorithm"
            Write-Host "Bytes     : $($bytes.Length)"
            Write-Host "Hash      : $hash" -ForegroundColor Green
            Write-Host ""

            Read-Host "Press ENTER"
        }
        catch {
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Read-Host "Press ENTER"
        }
    }
}

# -------------------------------------------------------------------------
# MAIN MENU
# -------------------------------------------------------------------------

function Show-MainMenu {

    while ($true) {

        Write-Title "BYTE-PRESERVING UNIVERSAL CONVERTER"

        Write-Host "ROOT DIRECTORY"
        Write-Host "  $ScriptRoot" -ForegroundColor DarkGray
        Write-Host ""

        Write-Host "1. Convert file → representation"
        Write-Host "2. Convert representation → original file"
        Write-Host "3. Byte-perfect DEFLATE round-trip test"
        Write-Host "4. Calculate file hash"
        Write-Host "5. Show compression architecture"
        Write-Host "6. Exit"
        Write-Host ""

        $choice = Read-Choice

        switch ($choice) {

            "1" {
                Show-ConvertMenu
            }

            "2" {
                Show-ReverseMenu
            }

            "3" {
                Show-RoundTripTest
            }

            "4" {
                Show-HashMenu
            }

            "5" {

                Write-Title "COMPRESSION / RESTORATION ARCHITECTURE"

                Write-Host ""
                Write-Host "FORWARD"
                Write-Host ""
                Write-Host "Original file"
                Write-Host "     │"
                Write-Host "     ▼"
                Write-Host "File.ReadAllBytes()"
                Write-Host "     │"
                Write-Host "     ▼"
                Write-Host "Original byte array"
                Write-Host "     │"
                Write-Host "     ▼"
                Write-Host "DEFLATE compression"
                Write-Host "     │"
                Write-Host "     ▼"
                Write-Host "Compressed byte array"
                Write-Host "     │"
                Write-Host "     ▼"
                Write-Host "BASE64 / HEX / BINARY / BYTE"
                Write-Host "     │"
                Write-Host "     ▼"
                Write-Host "Encoded representation"
                Write-Host ""
                Write-Host ""
                Write-Host "REVERSE"
                Write-Host ""
                Write-Host "Encoded representation"
                Write-Host "     │"
                Write-Host "     ▼"
                Write-Host "Decode representation"
                Write-Host "     │"
                Write-Host "     ▼"
                Write-Host "Compressed byte array"
                Write-Host "     │"
                Write-Host "     ▼"
                Write-Host "DEFLATE decompression"
                Write-Host "     │"
                Write-Host "     ▼"
                Write-Host "Original byte array"
                Write-Host "     │"
                Write-Host "     ▼"
				Write-Host 'File.WriteAllBytes()'
                Write-Host "     │"
                Write-Host "     ▼"
                Write-Host "Original file"
                Write-Host ""
                Write-Host "NO TEXT DECODING OCCURS DURING RESTORATION." -ForegroundColor Green
                Write-Host "This is what preserves the original byte sequence." -ForegroundColor Green
                Write-Host ""

                Read-Host "Press ENTER"
            }

            "6" {
                break
            }

            default {
                Write-Host ""
                Write-Host "Invalid option." -ForegroundColor Red
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

# -------------------------------------------------------------------------
# START
# -------------------------------------------------------------------------

Show-MainMenu

