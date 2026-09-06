#requires -Version 5.1

<#
===============================================================
 INTRANET FILE SERVER
===============================================================

 PowerShell 5.1+

 Features:
   - Persistent TUI main menu
   - Background HTTP server
   - Token authentication
   - Web file manager
   - List files
   - Upload multiple files
   - Download single files
   - Download multiple files as ZIP
   - Configurable port
   - Configurable shared folder
   - Configurable upload limit
   - Windows Firewall rule
   - Path traversal protection

 IMPORTANT:
   HTTP is unencrypted.
   Use this on a trusted private LAN only.
===============================================================
#>

$ErrorActionPreference = "Stop"

# =============================================================
# GLOBAL CONFIGURATION
# =============================================================

$ConfigDirectory = Join-Path `
    $env:ProgramData `
    "IntranetFileServer"

$ConfigFile = Join-Path `
    $ConfigDirectory `
    "config.json"

$Global:ServerJob = $null
$Global:ServerRunning = $false

# =============================================================
# DEFAULT CONFIGURATION
# =============================================================

$Config = @{
    Port         = 8080
    Root         = "C:\IntranetShare"
    AuthToken    = "CHANGE_ME"
    MaxUploadMB  = 2048
}

# =============================================================
# CREATE CONFIG DIRECTORY
# =============================================================

if (-not (Test-Path -LiteralPath $ConfigDirectory)) {

    New-Item `
        -ItemType Directory `
        -Path $ConfigDirectory `
        -Force |
        Out-Null
}

# =============================================================
# LOAD CONFIGURATION
# =============================================================

function Load-Configuration {

    if (Test-Path -LiteralPath $ConfigFile) {

        try {

            $Loaded =
                Get-Content `
                    -LiteralPath $ConfigFile `
                    -Raw |
                ConvertFrom-Json

            if ($null -ne $Loaded.Port) {
                $Config.Port = [int]$Loaded.Port
            }

            if ($null -ne $Loaded.Root) {
                $Config.Root = [string]$Loaded.Root
            }

            if ($null -ne $Loaded.AuthToken) {
                $Config.AuthToken =
                    [string]$Loaded.AuthToken
            }

            if ($null -ne $Loaded.MaxUploadMB) {
                $Config.MaxUploadMB =
                    [int]$Loaded.MaxUploadMB
            }

        }
        catch {

            Write-Host ""
            Write-Host "Configuration could not be loaded." `
                -ForegroundColor Yellow

            Write-Host "Using default configuration." `
                -ForegroundColor Yellow
        }
    }

    # Ensure root folder exists

    if (
        -not (
            Test-Path `
                -LiteralPath $Config.Root
        )
    ) {

        New-Item `
            -ItemType Directory `
            -Path $Config.Root `
            -Force |
            Out-Null
    }

    try {

        $Config.Root =
            (Resolve-Path `
                -LiteralPath $Config.Root).Path
    }
    catch {

        $Config.Root =
            "C:\IntranetShare"

        if (
            -not (
                Test-Path `
                    -LiteralPath $Config.Root
            )
        ) {

            New-Item `
                -ItemType Directory `
                -Path $Config.Root `
                -Force |
                Out-Null
        }
    }
}

# =============================================================
# SAVE CONFIGURATION
# =============================================================

function Save-Configuration {

    $Config |
        ConvertTo-Json -Depth 5 |
        Set-Content `
            -LiteralPath $ConfigFile `
            -Encoding UTF8
}

Load-Configuration
Save-Configuration

# =============================================================
# CONSOLE FUNCTIONS
# =============================================================

function Clear-TUI {

    Clear-Host

    [Console]::CursorVisible = $true
}

function Pause-TUI {

    Write-Host ""

    Write-Host `
        "Press any key to return to the main menu..." `
        -ForegroundColor DarkGray

    [void][Console]::ReadKey($true)
}

# =============================================================
# GENERATE RANDOM TOKEN
# =============================================================

function New-RandomToken {

    $Bytes =
        New-Object byte[] 32

    $RNG =
        [Security.Cryptography.RandomNumberGenerator]::Create()

    try {

        $RNG.GetBytes($Bytes)

    }
    finally {

        $RNG.Dispose()
    }

    return (
        [Convert]::ToBase64String($Bytes) `
            -replace '[^a-zA-Z0-9]', ''
    )
}

# =============================================================
# READ TOKEN
# =============================================================

function Read-NewToken {

    Write-Host ""

    $Token =
        Read-Host `
            "Enter new token/password"

    return $Token
}

# =============================================================
# SERVER INFORMATION
# =============================================================

function Show-ServerInfo {

    Clear-TUI

    Write-Host `
        "====================================================" `
        -ForegroundColor Cyan

    Write-Host `
        "                 SERVER INFORMATION" `
        -ForegroundColor Cyan

    Write-Host `
        "====================================================" `
        -ForegroundColor Cyan

    Write-Host ""

    Write-Host "Status:" -NoNewline

    if ($Global:ServerRunning) {

        Write-Host `
            " RUNNING" `
            -ForegroundColor Green
    }
    else {

        Write-Host `
            " STOPPED" `
            -ForegroundColor Red
    }

    Write-Host ""

    Write-Host "Shared folder:"
    Write-Host `
        "  $($Config.Root)" `
        -ForegroundColor Yellow

    Write-Host ""

    Write-Host "Port:"
    Write-Host `
        "  $($Config.Port)" `
        -ForegroundColor Yellow

    Write-Host ""

    Write-Host "Maximum upload:"
    Write-Host `
        "  $($Config.MaxUploadMB) MB" `
        -ForegroundColor Yellow

    Write-Host ""

    Write-Host "Web addresses:"
    Write-Host ""

    try {

        $Addresses =
            Get-NetIPAddress `
                -AddressFamily IPv4 `
                -ErrorAction Stop |
            Where-Object {

                $_.IPAddress -notlike "127.*" -and
                $_.IPAddress -notlike "169.254.*"

            } |
            Select-Object -ExpandProperty IPAddress

        if ($Addresses) {

            foreach ($Address in $Addresses) {

                Write-Host `
                    "  http://$Address`:$($Config.Port)/" `
                    -ForegroundColor Green
            }
        }
        else {

            Write-Host `
                "  No LAN IPv4 address found." `
                -ForegroundColor Yellow
        }

    }
    catch {

        Write-Host `
            "  Could not enumerate network addresses." `
            -ForegroundColor Yellow
    }

    Write-Host ""

    Write-Host "Authentication token:"
    Write-Host `
        "  $($Config.AuthToken)" `
        -ForegroundColor Magenta

    Write-Host ""

    Pause-TUI
}

# =============================================================
# CHANGE TOKEN
# =============================================================

function Change-Token {

    Clear-TUI

    Write-Host `
        "====================================================" `
        -ForegroundColor Cyan

    Write-Host `
        "                TOKEN / PASSWORD" `
        -ForegroundColor Cyan

    Write-Host `
        "====================================================" `
        -ForegroundColor Cyan

    Write-Host ""

    Write-Host "1. Generate random token"
    Write-Host "2. Enter custom token"
    Write-Host "3. Cancel"

    Write-Host ""

    $Choice =
        Read-Host "Select"

    switch ($Choice) {

        "1" {

            $Config.AuthToken =
                New-RandomToken

            Save-Configuration

            Write-Host ""

            Write-Host `
                "New token:" `
                -ForegroundColor Green

            Write-Host `
                $Config.AuthToken `
                -ForegroundColor Yellow

            Write-Host ""

            Write-Host `
                "Restart the server for the new token to take effect." `
                -ForegroundColor Yellow

            Pause-TUI
        }

        "2" {

            $NewToken =
                Read-NewToken

            if (
                [string]::IsNullOrWhiteSpace(
                    $NewToken
                )
            ) {

                Write-Host ""

                Write-Host `
                    "Token cannot be empty." `
                    -ForegroundColor Red
            }
            else {

                $Config.AuthToken =
                    $NewToken

                Save-Configuration

                Write-Host ""

                Write-Host `
                    "Token changed." `
                    -ForegroundColor Green

                Write-Host `
                    "Restart the server for the new token to take effect." `
                    -ForegroundColor Yellow
            }

            Pause-TUI
        }

        default {
        }
    }
}

# =============================================================
# CHANGE PORT
# =============================================================

function Change-Port {

    Clear-TUI

    Write-Host `
        "====================================================" `
        -ForegroundColor Cyan

    Write-Host `
        "                     PORT" `
        -ForegroundColor Cyan

    Write-Host `
        "====================================================" `
        -ForegroundColor Cyan

    Write-Host ""

    Write-Host `
        "Current port: $($Config.Port)"

    Write-Host ""

    $InputPort =
        Read-Host `
            "Enter new port"

    $PortValue = 0

    if (
        [int]::TryParse(
            $InputPort,
            [ref]$PortValue
        )
    ) {

        if (
            $PortValue -ge 1 -and
            $PortValue -le 65535
        ) {

            $Config.Port =
                $PortValue

            Save-Configuration

            Write-Host ""

            Write-Host `
                "Port changed to $PortValue." `
                -ForegroundColor Green

            Write-Host `
                "Restart the server to apply the new port." `
                -ForegroundColor Yellow
        }
        else {

            Write-Host ""

            Write-Host `
                "Port must be between 1 and 65535." `
                -ForegroundColor Red
        }
    }
    else {

        Write-Host ""

        Write-Host `
            "Invalid port." `
            -ForegroundColor Red
    }

    Pause-TUI
}

# =============================================================
# CHANGE ROOT
# =============================================================

function Change-Root {

    Clear-TUI

    Write-Host `
        "====================================================" `
        -ForegroundColor Cyan

    Write-Host `
        "                  SHARED FOLDER" `
        -ForegroundColor Cyan

    Write-Host `
        "====================================================" `
        -ForegroundColor Cyan

    Write-Host ""

    Write-Host `
        "Current folder:"

    Write-Host `
        $Config.Root `
        -ForegroundColor Yellow

    Write-Host ""

    $NewRoot =
        Read-Host `
            "Enter new folder"

    if (
        [string]::IsNullOrWhiteSpace(
            $NewRoot
        )
    ) {

        Pause-TUI
        return
    }

    try {

        if (
            -not (
                Test-Path `
                    -LiteralPath $NewRoot
            )
        ) {

            New-Item `
                -ItemType Directory `
                -Path $NewRoot `
                -Force |
                Out-Null
        }

        $Config.Root =
            (Resolve-Path `
                -LiteralPath $NewRoot).Path

        Save-Configuration

        Write-Host ""

        Write-Host `
            "Shared folder changed." `
            -ForegroundColor Green

        Write-Host `
            "Restart the server to apply it." `
            -ForegroundColor Yellow
    }
    catch {

        Write-Host ""

        Write-Host `
            "Failed to change folder:" `
            -ForegroundColor Red

        Write-Host `
            $_.Exception.Message
    }

    Pause-TUI
}

# =============================================================
# CHANGE UPLOAD LIMIT
# =============================================================

function Change-MaxUpload {

    Clear-TUI

    Write-Host `
        "====================================================" `
        -ForegroundColor Cyan

    Write-Host `
        "                 UPLOAD LIMIT" `
        -ForegroundColor Cyan

    Write-Host `
        "====================================================" `
        -ForegroundColor Cyan

    Write-Host ""

    Write-Host `
        "Current limit: $($Config.MaxUploadMB) MB"

    Write-Host ""

    $InputValue =
        Read-Host `
            "New maximum MB"

    $MB = 0

    if (
        [int]::TryParse(
            $InputValue,
            [ref]$MB
        ) -and
        $MB -gt 0
    ) {

        $Config.MaxUploadMB =
            $MB

        Save-Configuration

        Write-Host ""

        Write-Host `
            "Upload limit changed." `
            -ForegroundColor Green

        Write-Host `
            "Restart the server to apply it." `
            -ForegroundColor Yellow
    }
    else {

        Write-Host ""

        Write-Host `
            "Invalid value." `
            -ForegroundColor Red
    }

    Pause-TUI
}

# =============================================================
# FIREWALL RULE
# =============================================================

function Add-IntranetFirewallRule {

    Clear-TUI

    Write-Host `
        "====================================================" `
        -ForegroundColor Cyan

    Write-Host `
        "                WINDOWS FIREWALL" `
        -ForegroundColor Cyan

    Write-Host `
        "====================================================" `
        -ForegroundColor Cyan

    Write-Host ""

    $RuleName =
        "Intranet File Server TCP $($Config.Port)"

    try {

        $Existing =
            Get-NetFirewallRule `
                -DisplayName $RuleName `
                -ErrorAction SilentlyContinue

        if ($Existing) {

            Remove-NetFirewallRule `
                -DisplayName $RuleName `
                -ErrorAction SilentlyContinue
        }

        New-NetFirewallRule `
            -DisplayName $RuleName `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort $Config.Port `
            -Action Allow `
            -Profile Private `
            -ErrorAction Stop |
            Out-Null

        Write-Host `
            "Firewall rule created:" `
            -ForegroundColor Green

        Write-Host `
            $RuleName

    }
    catch {

        Write-Host `
            "Failed to create firewall rule." `
            -ForegroundColor Red

        Write-Host ""
        Write-Host $_.Exception.Message
        Write-Host ""

        Write-Host `
            "Run PowerShell as Administrator if required." `
            -ForegroundColor Yellow
    }

    Pause-TUI
}

# =============================================================
# CHECK SERVER JOB
# =============================================================

function Update-ServerState {

    if (-not $Global:ServerJob) {

        $Global:ServerRunning = $false

        return
    }

    $State =
        $Global:ServerJob.State

    if ($State -eq "Running") {

        $Global:ServerRunning = $true
    }
    elseif (
        $State -eq "Failed" -or
        $State -eq "Completed" -or
        $State -eq "Stopped"
    ) {

        $Global:ServerRunning = $false
    }
}

# =============================================================
# START SERVER
# =============================================================

function Start-FileServer {

    Update-ServerState

    if ($Global:ServerRunning) {

        Write-Host ""

        Write-Host `
            "Server is already running." `
            -ForegroundColor Yellow

        Start-Sleep -Milliseconds 700

        return
    }

    # ---------------------------------------------------------
    # Save configuration
    # ---------------------------------------------------------

    Save-Configuration

    # ---------------------------------------------------------
    # Capture configuration
    # ---------------------------------------------------------

    $ServerPort =
        [int]$Config.Port

    $ServerRoot =
        [string]$Config.Root

    $ServerToken =
        [string]$Config.AuthToken

    $ServerMaxUpload =
        [int]$Config.MaxUploadMB

    $ServerWebPage =
        [string]$WebPage

    # ---------------------------------------------------------
    # Start background job
    # ---------------------------------------------------------

    $Global:ServerJob =
        Start-Job -ScriptBlock {

            param(
                $Port,
                $Root,
                $Token,
                $MaxUploadMB,
                $WebPage
            )

            $ErrorActionPreference = "Stop"

            # =================================================
            # SAFE PATH
            # =================================================

            function Get-SafePath {

                param(
                    [string]$RelativePath
                )

                if (
                    [string]::IsNullOrWhiteSpace(
                        $RelativePath
                    )
                ) {

                    return $null
                }

                try {

                    $Decoded =
                        [Uri]::UnescapeDataString(
                            $RelativePath
                        )
                }
                catch {

                    return $null
                }

                $Decoded =
                    $Decoded.Replace(
                        "/",
                        "\"
                    )

                $Decoded =
                    $Decoded.TrimStart("\")

                # Block traversal
                if (
                    $Decoded -match
                    '(^|\\)\.\.(\\|$)'
                ) {

                    return $null
                }

                # Block absolute paths
                if (
                    [IO.Path]::IsPathRooted(
                        $Decoded
                    )
                ) {

                    return $null
                }

                try {

                    $Full =
                        [IO.Path]::GetFullPath(
                            (
                                Join-Path `
                                    $Root `
                                    $Decoded
                            )
                        )

                    $RootPrefix =
                        $Root.TrimEnd("\") + "\"

                    if (
                        -not $Full.StartsWith(
                            $RootPrefix,
                            [StringComparison]::OrdinalIgnoreCase
                        )
                    ) {

                        return $null
                    }

                    return $Full
                }
                catch {

                    return $null
                }
            }

            # =================================================
            # AUTHENTICATION
            # =================================================

            function Test-Token {

                param(
                    $Request
                )

                $RequestToken =
                    $Request.Headers[
                        "X-Auth-Token"
                    ]

                if (
                    [string]::IsNullOrWhiteSpace(
                        $RequestToken
                    )
                ) {

                    return $false
                }

                return (
                    [StringComparer]::Ordinal.Equals(
                        $RequestToken,
                        $Token
                    )
                )
            }

            # =================================================
            # SEND BYTES
            # =================================================

            function Send-Bytes {

                param(
                    $Response,
                    [int]$Status,
                    [string]$ContentType,
                    [byte[]]$Data
                )

                $Response.StatusCode =
                    $Status

                $Response.ContentType =
                    $ContentType

                $Response.ContentLength64 =
                    $Data.Length

                try {

                    $Response.OutputStream.Write(
                        $Data,
                        0,
                        $Data.Length
                    )
                }
                catch {
                }
                finally {

                    try {
                        $Response.OutputStream.Close()
                    }
                    catch {
                    }
                }
            }

            # =================================================
            # SEND TEXT
            # =================================================

            function Send-Text {

                param(
                    $Response,
                    [int]$Status,
                    [string]$Text
                )

                $Data =
                    [Text.Encoding]::UTF8.GetBytes(
                        $Text
                    )

                Send-Bytes `
                    $Response `
                    $Status `
                    "text/plain; charset=utf-8" `
                    $Data
            }

            # =================================================
            # SEND JSON
            # =================================================

            function Send-JSON {

                param(
                    $Response,
                    [int]$Status,
                    $Object
                )

                $JSON =
                    $Object |
                    ConvertTo-Json -Depth 10

                $Data =
                    [Text.Encoding]::UTF8.GetBytes(
                        $JSON
                    )

                Send-Bytes `
                    $Response `
                    $Status `
                    "application/json; charset=utf-8" `
                    $Data
            }

            # =================================================
            # ENSURE ROOT
            # =================================================

            if (
                -not (
                    Test-Path `
                        -LiteralPath $Root
                )
            ) {

                New-Item `
                    -ItemType Directory `
                    -Path $Root `
                    -Force |
                    Out-Null
            }

            # =================================================
            # HTTP LISTENER
            # =================================================

            $Listener =
                New-Object `
                    System.Net.HttpListener

            $Listener.Prefixes.Add(
                "http://+:$Port/"
            )

            try {

                $Listener.Start()

                Write-Output `
                    "SERVER_STARTED"
            }
            catch {

                Write-Output (
                    "SERVER_ERROR: " +
                    $_.Exception.Message
                )

                exit
            }

            # =================================================
            # REQUEST LOOP
            # =================================================

            while (
                $Listener.IsListening
            ) {

                try {

                    $Context =
                        $Listener.GetContext()
                }
                catch {

                    break
                }

                $Request =
                    $Context.Request

                $Response =
                    $Context.Response

                $Method =
                    $Request.HttpMethod.ToUpperInvariant()

                $Path =
                    $Request.Url.AbsolutePath

                # -------------------------------------------------
                # CORS
                # -------------------------------------------------

                try {

                    $Response.Headers.Add(
                        "Access-Control-Allow-Origin",
                        "*"
                    )

                    $Response.Headers.Add(
                        "Access-Control-Allow-Headers",
                        "X-Auth-Token,X-Filename,Content-Type"
                    )

                    $Response.Headers.Add(
                        "Access-Control-Allow-Methods",
                        "GET,POST,OPTIONS"
                    )
                }
                catch {
                }

                # =================================================
                # OPTIONS
                # =================================================

                if (
                    $Method -eq "OPTIONS"
                ) {

                    Send-Text `
                        $Response `
                        200 `
                        "OK"

                    continue
                }

                # =================================================
                # WEB PANEL
                # =================================================

                if (
                    $Path -eq "/" -and
                    $Method -eq "GET"
                ) {

                    $Data =
                        [Text.Encoding]::UTF8.GetBytes(
                            $WebPage
                        )

                    Send-Bytes `
                        $Response `
                        200 `
                        "text/html; charset=utf-8" `
                        $Data

                    continue
                }

                # =================================================
                # AUTH
                # =================================================

                if (
                    -not (
                        Test-Token $Request
                    )
                ) {

                    Send-Text `
                        $Response `
                        401 `
                        "Unauthorized"

                    continue
                }

                # =================================================
                # LIST FILES
                # =================================================

                if (
                    $Path -eq "/list" -and
                    $Method -eq "GET"
                ) {

                    try {

                        $Files =
                            Get-ChildItem `
                                -LiteralPath $Root `
                                -File `
                                -Recurse `
                                -ErrorAction Stop

                        $Result =
                            @()

                        foreach (
                            $File in $Files
                        ) {

                            $Relative =
                                $File.FullName.Substring(
                                    $Root.Length
                                ).TrimStart("\")

                            $Result +=
                                [PSCustomObject]@{

                                    Name =
                                        (
                                            $Relative `
                                                -replace "\\","/"
                                        )

                                    Size =
                                        [int64]$File.Length

                                    Modified =
                                        $File.LastWriteTime.ToString(
                                            "yyyy-MM-dd HH:mm:ss"
                                        )
                                }
                        }

                        Send-JSON `
                            $Response `
                            200 `
                            $Result
                    }
                    catch {

                        Send-Text `
                            $Response `
                            500 `
                            $_.Exception.Message
                    }

                    continue
                }

                # =================================================
                # SINGLE DOWNLOAD
                # =================================================

                if (
                    $Path.StartsWith(
                        "/download/"
                    ) -and
                    $Method -eq "GET"
                ) {

                    $Relative =
                        $Path.Substring(
                            "/download/".Length
                        )

                    $FilePath =
                        Get-SafePath `
                            $Relative

                    if (-not $FilePath) {

                        Send-Text `
                            $Response `
                            400 `
                            "Invalid path"

                        continue
                    }

                    if (
                        -not (
                            Test-Path `
                                -LiteralPath $FilePath `
                                -PathType Leaf
                        )
                    ) {

                        Send-Text `
                            $Response `
                            404 `
                            "File not found"

                        continue
                    }

                    try {

                        $File =
                            Get-Item `
                                -LiteralPath $FilePath

                        $Response.StatusCode =
                            200

                        $Response.ContentType =
                            "application/octet-stream"

                        $Response.ContentLength64 =
                            $File.Length

                        $Stream =
                            [IO.File]::OpenRead(
                                $FilePath
                            )

                        try {

                            $Buffer =
                                New-Object byte[] 65536

                            while (
                                (
                                    $Read =
                                        $Stream.Read(
                                            $Buffer,
                                            0,
                                            $Buffer.Length
                                        )
                                ) -gt 0
                            ) {

                                $Response.OutputStream.Write(
                                    $Buffer,
                                    0,
                                    $Read
                                )
                            }
                        }
                        finally {

                            $Stream.Close()

                            $Response.OutputStream.Close()
                        }
                    }
                    catch {

                        try {
                            $Response.OutputStream.Close()
                        }
                        catch {
                        }
                    }

                    continue
                }

                # =================================================
                # MULTIPLE DOWNLOAD
                # =================================================

                if (
                    $Path -eq "/download-multiple" -and
                    $Method -eq "POST"
                ) {

                    $TempZip = $null

                    try {

                        $Reader =
                            New-Object `
                                IO.StreamReader(
                                    $Request.InputStream
                                )

                        $Body =
                            $Reader.ReadToEnd()

                        $Reader.Close()

                        $Names =
                            $Body |
                            ConvertFrom-Json

                        if (
                            -not $Names
                        ) {

                            Send-Text `
                                $Response `
                                400 `
                                "No files selected"

                            continue
                        }

                        Add-Type `
                            -AssemblyName `
                            System.IO.Compression.FileSystem

                        $TempZip =
                            Join-Path `
                                ([IO.Path]::GetTempPath()) `
                                (
                                    "intranet-" +
                                    [Guid]::NewGuid().ToString() +
                                    ".zip"
                                )

                        $Zip =
                            [IO.Compression.ZipFile]::Open(
                                $TempZip,
                                [IO.Compression.ZipArchiveMode]::Create
                            )

                        try {

                            foreach (
                                $Name in $Names
                            ) {

                                if (
                                    -not (
                                        $Name -is [string]
                                    )
                                ) {

                                    continue
                                }

                                $FilePath =
                                    Get-SafePath `
                                        $Name

                                if (
                                    -not $FilePath
                                ) {

                                    continue
                                }

                                if (
                                    -not (
                                        Test-Path `
                                            -LiteralPath $FilePath `
                                            -PathType Leaf
                                    )
                                ) {

                                    continue
                                }

                                $RelativeName =
                                    $Name `
                                        -replace "\\","/"

                                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                                    $Zip,
                                    $FilePath,
                                    $RelativeName,
                                    [IO.Compression.CompressionLevel]::Fastest
                                )
                            }
                        }
                        finally {

                            $Zip.Dispose()
                        }

                        $Bytes =
                            [IO.File]::ReadAllBytes(
                                $TempZip
                            )

                        Send-Bytes `
                            $Response `
                            200 `
                            "application/zip" `
                            $Bytes
                    }
                    catch {

                        Send-Text `
                            $Response `
                            500 `
                            (
                                "ZIP creation failed: " +
                                $_.Exception.Message
                            )
                    }
                    finally {

                        if (
                            $TempZip -and
                            (
                                Test-Path `
                                    -LiteralPath $TempZip
                            )
                        ) {

                            Remove-Item `
                                -LiteralPath $TempZip `
                                -Force `
                                -ErrorAction SilentlyContinue
                        }
                    }

                    continue
                }

                # =================================================
                # UPLOAD
                # =================================================

                if (
                    $Path -eq "/upload" -and
                    $Method -eq "POST"
                ) {

                    $Filename =
                        $Request.Headers[
                            "X-Filename"
                        ]

                    if (
                        [string]::IsNullOrWhiteSpace(
                            $Filename
                        )
                    ) {

                        Send-Text `
                            $Response `
                            400 `
                            "Missing filename"

                        continue
                    }

                    # Prevent directory injection
                    $Filename =
                        [IO.Path]::GetFileName(
                            $Filename
                        )

                    foreach (
                        $InvalidChar in
                        [IO.Path]::GetInvalidFileNameChars()
                    ) {

                        $Filename =
                            $Filename.Replace(
                                [string]$InvalidChar,
                                "_"
                            )
                    }

                    if (
                        [string]::IsNullOrWhiteSpace(
                            $Filename
                        )
                    ) {

                        Send-Text `
                            $Response `
                            400 `
                            "Invalid filename"

                        continue
                    }

                    $Destination =
                        Join-Path `
                            $Root `
                            $Filename

                    $MaxBytes =
                        [int64]$MaxUploadMB * 1MB

                    if (
                        $Request.ContentLength64 -gt
                        $MaxBytes
                    ) {

                        Send-Text `
                            $Response `
                            413 `
                            "File exceeds upload limit"

                        continue
                    }

                    try {

                        $Stream =
                            [IO.File]::Create(
                                $Destination
                            )

                        try {

                            $Buffer =
                                New-Object byte[] 65536

                            $Total = 0L

                            while (
                                (
                                    $Read =
                                        $Request.InputStream.Read(
                                            $Buffer,
                                            0,
                                            $Buffer.Length
                                        )
                                ) -gt 0
                            ) {

                                $Total += $Read

                                if (
                                    $Total -gt
                                    $MaxBytes
                                ) {

                                    throw `
                                        "Upload exceeds configured limit."
                                }

                                $Stream.Write(
                                    $Buffer,
                                    0,
                                    $Read
                                )
                            }
                        }
                        finally {

                            $Stream.Close()
                        }

                        $SavedFile =
                            Get-Item `
                                -LiteralPath $Destination

                        Send-JSON `
                            $Response `
                            200 `
                            @{
                                success =
                                    $true

                                filename =
                                    $Filename

                                size =
                                    [int64]$SavedFile.Length
                            }
                    }
                    catch {

                        if (
                            Test-Path `
                                -LiteralPath $Destination
                        ) {

                            Remove-Item `
                                -LiteralPath $Destination `
                                -Force `
                                -ErrorAction SilentlyContinue
                        }

                        Send-Text `
                            $Response `
                            500 `
                            (
                                "Upload failed: " +
                                $_.Exception.Message
                            )
                    }

                    continue
                }

                # =================================================
                # 404
                # =================================================

                Send-Text `
                    $Response `
                    404 `
                    "Not found"
            }

            # =================================================
            # SERVER SHUTDOWN
            # =================================================

            try {
                $Listener.Stop()
            }
            catch {
            }

            try {
                $Listener.Close()
            }
            catch {
            }

        } -ArgumentList `
            $ServerPort,
            $ServerRoot,
            $ServerToken,
            $ServerMaxUpload,
            $ServerWebPage

    # ---------------------------------------------------------
    # Mark server running
    # ---------------------------------------------------------

    $Global:ServerRunning = $true

    Write-Host ""

    Write-Host `
        "Server started in background." `
        -ForegroundColor Green

    Write-Host `
        "Returning to main menu..." `
        -ForegroundColor DarkGray

    Start-Sleep -Milliseconds 700
}

# =============================================================
# STOP SERVER
# =============================================================

function Stop-FileServer {

    Update-ServerState

    if (-not $Global:ServerJob) {

        $Global:ServerRunning = $false

        Write-Host ""

        Write-Host `
            "Server is already stopped." `
            -ForegroundColor Yellow

        Start-Sleep -Milliseconds 600

        return
    }

    try {

        Stop-Job `
            -Job $Global:ServerJob `
            -ErrorAction SilentlyContinue

        Remove-Job `
            -Job $Global:ServerJob `
            -Force `
            -ErrorAction SilentlyContinue
    }
    catch {
    }

    $Global:ServerJob =
        $null

    $Global:ServerRunning =
        $false

    Write-Host ""

    Write-Host `
        "Server stopped." `
        -ForegroundColor Yellow

    Start-Sleep -Milliseconds 700
}

# =============================================================
# SAVE CONFIGURATION MENU OPTION
# =============================================================

function Save-ConfigurationMenu {

    Save-Configuration

    Write-Host ""

    Write-Host `
        "Configuration saved." `
        -ForegroundColor Green

    Start-Sleep -Milliseconds 700
}

# =============================================================
# WEB PANEL
# =============================================================

$WebPage = @'
<!DOCTYPE html>

<html>

<head>

<meta charset="UTF-8">

<meta name="viewport"
      content="width=device-width,initial-scale=1">

<title>Intranet File Manager</title>

<style>

* {
    box-sizing: border-box;
}

body {
    margin: 0;
    background: #101217;
    color: #e8e8e8;
    font-family: Arial, Helvetica, sans-serif;
}

header {
    padding: 18px 25px;
    background: #181b22;
    border-bottom: 1px solid #30343d;
}

header h1 {
    margin: 0;
    font-size: 22px;
}

.container {
    max-width: 1400px;
    margin: auto;
    padding: 25px;
}

.panel {
    background: #181b22;
    border: 1px solid #30343d;
    border-radius: 8px;
    padding: 20px;
    margin-bottom: 20px;
}

.login {
    max-width: 500px;
    margin: 80px auto;
}

input[type=password] {
    width: 100%;
    padding: 12px;
    margin-bottom: 12px;
    background: #0d0f13;
    border: 1px solid #444;
    color: white;
    border-radius: 5px;
}

input[type=file] {
    max-width: 100%;
}

button {
    border: 0;
    border-radius: 5px;
    padding: 10px 15px;
    cursor: pointer;
    background: #2e7dff;
    color: white;
    margin: 3px;
}

button:hover {
    opacity: .85;
}

button.secondary {
    background: #3c414b;
}

button.danger {
    background: #a83232;
}

.drop {
    border: 2px dashed #444;
    padding: 25px;
    text-align: center;
    border-radius: 8px;
}

.drop:hover {
    border-color: #2e7dff;
}

.status {
    padding: 10px;
    background: #0d0f13;
    border-radius: 5px;
    margin-top: 12px;
    white-space: pre-wrap;
}

.progress-container {
    margin-top: 12px;
    padding: 12px;
    background: #0d0f13;
    border-radius: 6px;
}

.progress-row {
    display: flex;
    justify-content: space-between;
    gap: 12px;
    margin-bottom: 7px;
    font-size: 13px;
}

.progress-track {
    width: 100%;
    height: 18px;
    background: #252932;
    border: 1px solid #3b404a;
    border-radius: 999px;
    overflow: hidden;
}

.progress-bar {
    width: 0%;
    height: 100%;
    background: #2e7dff;
    transition: width .08s linear;
}

.progress-percent {
    margin-top: 6px;
    text-align: right;
    font-weight: bold;
    color: #7fb0ff;
}

.progress-complete {
    background: #35a85b;
}

.small {
    color: #999;
    font-size: 13px;
}

.hidden {
    display: none;
}

.table-container {
    overflow-x: auto;
}

table {
    width: 100%;
    border-collapse: collapse;
}

th,
td {
    padding: 10px;
    border-bottom: 1px solid #30343d;
    text-align: left;
}

tr:hover {
    background: #20242c;
}

.fileName {
    word-break: break-all;
}

</style>

</head>

<body>

<header>

<h1>
Intranet File Manager
</h1>

</header>

<!-- ======================================================
     LOGIN
====================================================== -->

<div id="loginPanel"
     class="container">

    <div class="panel login">

        <h2>
            Authentication
        </h2>

        <p class="small">
            Enter the server token/password.
        </p>

        <input
            id="token"
            type="password"
            placeholder="Token / password">

        <button onclick="login()">
            Connect
        </button>

        <div id="loginStatus"
             class="status">
        </div>

    </div>

</div>

<!-- ======================================================
     MAIN PANEL
====================================================== -->

<div id="mainPanel"
     class="container hidden">

    <!-- OPERATIONS -->

    <div class="panel">

        <h2>
            File Operations
        </h2>

        <button onclick="refreshFiles()">
            Refresh
        </button>

        <button
            class="secondary"
            onclick="selectAll(true)">
            Select All
        </button>

        <button
            class="secondary"
            onclick="selectAll(false)">
            Clear Selection
        </button>

        <button onclick="downloadSelected()">
            Download Selected
        </button>

        <button
            class="danger"
            onclick="logout()">
            Logout
        </button>

    </div>

    <!-- UPLOAD -->

    <div class="panel">

        <h2>
            Upload Multiple Files
        </h2>

        <div class="drop">

            <input
                id="uploadFiles"
                type="file"
                multiple>

            <br><br>

            <button onclick="uploadFiles()">
                Upload Selected Files
            </button>

        </div>

        <div id="uploadStatus"
             class="status">

            No uploads running.

        </div>

        <div class="progress-container">
            <div class="progress-row">
                <span id="uploadProgressName">Upload progress</span>
                <span id="uploadProgressBytes">0 B / 0 B</span>
            </div>
            <div class="progress-track">
                <div id="uploadProgressBar"
                     class="progress-bar"></div>
            </div>
            <div id="uploadProgressPercent"
                 class="progress-percent">0%</div>
        </div>

    </div>

    <!-- FILE LIST -->

    <div class="panel">

        <h2>
            Files
        </h2>

        <div id="fileStatus"
             class="status">

            Loading...

        </div>

        <div class="table-container">

            <table>

                <thead>

                    <tr>

                        <th>
                            Select
                        </th>

                        <th>
                            File
                        </th>

                        <th>
                            Size
                        </th>

                        <th>
                            Modified
                        </th>

                        <th>
                            Action
                        </th>

                    </tr>

                </thead>

                <tbody id="fileTable">
                </tbody>

            </table>

        </div>

    </div>

</div>

<script>

let authToken = "";


// ========================================================
// LOGIN
// ========================================================

function login() {

    const value =
        document.getElementById(
            "token"
        ).value;

    if (!value) {

        document.getElementById(
            "loginStatus"
        ).textContent =
            "Enter a token.";

        return;
    }

    authToken =
        value;

    fetch(
        "/list",
        {
            headers: {
                "X-Auth-Token":
                    authToken
            }
        }
    )
    .then(
        response => {

            if (!response.ok) {

                throw new Error(
                    "Authentication failed."
                );
            }

            return response.json();
        }
    )
    .then(
        data => {

            document
                .getElementById(
                    "loginPanel"
                )
                .classList
                .add("hidden");

            document
                .getElementById(
                    "mainPanel"
                )
                .classList
                .remove("hidden");

            renderFiles(data);
        }
    )
    .catch(
        error => {

            authToken = "";

            document
                .getElementById(
                    "loginStatus"
                )
                .textContent =
                    error.message;
        }
    );
}


// ========================================================
// LOGOUT
// ========================================================

function logout() {

    authToken = "";

    document
        .getElementById(
            "mainPanel"
        )
        .classList
        .add("hidden");

    document
        .getElementById(
            "loginPanel"
        )
        .classList
        .remove("hidden");

    document
        .getElementById(
            "token"
        )
        .value = "";

    document
        .getElementById(
            "fileTable"
        )
        .innerHTML = "";
}


// ========================================================
// REFRESH FILES
// ========================================================

function refreshFiles() {

    fetch(
        "/list",
        {
            headers: {
                "X-Auth-Token":
                    authToken
            }
        }
    )
    .then(
        response => {

            if (!response.ok) {

                throw new Error(
                    "Access denied."
                );
            }

            return response.json();
        }
    )
    .then(
        data => {

            renderFiles(data);
        }
    )
    .catch(
        error => {

            document
                .getElementById(
                    "fileStatus"
                )
                .textContent =
                    error.message;
        }
    );
}


// ========================================================
// FORMAT SIZE
// ========================================================

function formatBytes(bytes) {

    if (bytes === 0) {
        return "0 B";
    }

    const units = [
        "B",
        "KB",
        "MB",
        "GB",
        "TB"
    ];

    const index =
        Math.floor(
            Math.log(bytes) /
            Math.log(1024)
        );

    return (
        bytes /
        Math.pow(1024, index)
    ).toFixed(2)
    + " "
    + units[index];
}


// ========================================================
// RENDER FILES
// ========================================================

function renderFiles(files) {

    const table =
        document.getElementById(
            "fileTable"
        );

    table.innerHTML = "";

    document
        .getElementById(
            "fileStatus"
        )
        .textContent =
            files.length +
            " file(s)";

    for (
        let i = 0;
        i < files.length;
        i++
    ) {

        const file =
            files[i];

        const tr =
            document.createElement(
                "tr"
            );

        // SELECT

        const tdSelect =
            document.createElement(
                "td"
            );

        const checkbox =
            document.createElement(
                "input"
            );

        checkbox.type =
            "checkbox";

        checkbox.className =
            "fileCheck";

        checkbox.dataset.file =
            file.Name;

        tdSelect.appendChild(
            checkbox
        );

        // NAME

        const tdName =
            document.createElement(
                "td"
            );

        tdName.className =
            "fileName";

        tdName.textContent =
            file.Name;

        // SIZE

        const tdSize =
            document.createElement(
                "td"
            );

        tdSize.textContent =
            formatBytes(
                file.Size
            );

        // MODIFIED

        const tdModified =
            document.createElement(
                "td"
            );

        tdModified.textContent =
            file.Modified;

        // ACTION

        const tdAction =
            document.createElement(
                "td"
            );

        const button =
            document.createElement(
                "button"
            );

        button.textContent =
            "Download";

        button.onclick =
            function() {

                downloadFile(
                    file.Name
                );
            };

        tdAction.appendChild(
            button
        );

        // ROW

        tr.appendChild(
            tdSelect
        );

        tr.appendChild(
            tdName
        );

        tr.appendChild(
            tdSize
        );

        tr.appendChild(
            tdModified
        );

        tr.appendChild(
            tdAction
        );

        table.appendChild(
            tr
        );
    }
}


// ========================================================
// SELECT ALL
// ========================================================

function selectAll(value) {

    document
        .querySelectorAll(
            ".fileCheck"
        )
        .forEach(
            checkbox => {

                checkbox.checked =
                    value;
            }
        );
}


// ========================================================
// DOWNLOAD SINGLE
// ========================================================

function downloadFile(name) {

    const encoded =
        name
            .split("/")
            .map(
                part =>
                    encodeURIComponent(part)
            )
            .join("/");

    const xhr =
        new XMLHttpRequest();

    xhr.open(
        "GET",
        "/download/" + encoded,
        true
    );

    xhr.responseType = "blob";

    xhr.setRequestHeader(
        "X-Auth-Token",
        authToken
    );

    const progressName =
        document.getElementById(
            "uploadProgressName"
        );

    const progressBytes =
        document.getElementById(
            "uploadProgressBytes"
        );

    const progressBar =
        document.getElementById(
            "uploadProgressBar"
        );

    const progressPercent =
        document.getElementById(
            "uploadProgressPercent"
        );

    progressName.textContent =
        "Downloading: " +
        name.split("/").pop();

    progressBytes.textContent =
        "0 B / 0 B";

    progressBar.style.width =
        "0%";

    progressBar.classList.remove(
        "progress-complete"
    );

    progressPercent.textContent =
        "0%";

    xhr.onprogress =
        function(event) {

            if (event.lengthComputable) {

                const percent =
                    Math.min(
                        100,
                        Math.round(
                            (event.loaded /
                             event.total) * 100
                        )
                    );

                progressBar.style.width =
                    percent + "%";

                progressPercent.textContent =
                    percent + "%";

                progressBytes.textContent =
                    formatBytes(event.loaded) +
                    " / " +
                    formatBytes(event.total);
            }
            else {

                progressBytes.textContent =
                    formatBytes(event.loaded) +
                    " / unknown";

                progressPercent.textContent =
                    "Receiving...";
            }
        };

    xhr.onload =
        function() {

            if (
                xhr.status < 200 ||
                xhr.status >= 300
            ) {

                let message =
                    "Download failed.";

                try {
                    message =
                        xhr.responseText ||
                        message;
                }
                catch (_) {
                }

                progressName.textContent =
                    "Download failed";

                alert(message);
                return;
            }

            progressBar.style.width =
                "100%";

            progressPercent.textContent =
                "100%";

            progressBar.classList.add(
                "progress-complete"
            );

            progressBytes.textContent =
                formatBytes(
                    xhr.response.size
                ) +
                " / " +
                formatBytes(
                    xhr.response.size
                );

            const url =
                URL.createObjectURL(
                    xhr.response
                );

            const a =
                document.createElement(
                    "a"
                );

            a.href = url;

            a.download =
                name
                    .split("/")
                    .pop();

            document.body.appendChild(a);
            a.click();
            a.remove();

            setTimeout(
                function() {
                    URL.revokeObjectURL(url);
                },
                1000
            );
        };

    xhr.onerror =
        function() {

            progressName.textContent =
                "Download failed";

            alert(
                "Network error while downloading."
            );
        };

    xhr.onabort =
        function() {

            progressName.textContent =
                "Download cancelled";
        };

    xhr.send();
}


// ========================================================
// MULTIPLE DOWNLOAD
// ========================================================


function downloadSelected() {

    const selected =
        Array.from(
            document.querySelectorAll(
                ".fileCheck:checked"
            )
        )
        .map(
            checkbox =>
                checkbox.dataset.file
        );

    if (
        selected.length === 0
    ) {

        alert(
            "Select at least one file."
        );

        return;
    }

    const status =
        document.getElementById(
            "uploadStatus"
        );

    const progressName =
        document.getElementById(
            "uploadProgressName"
        );

    const progressBytes =
        document.getElementById(
            "uploadProgressBytes"
        );

    const progressBar =
        document.getElementById(
            "uploadProgressBar"
        );

    const progressPercent =
        document.getElementById(
            "uploadProgressPercent"
        );

    status.textContent =
        "Preparing ZIP download...";

    progressName.textContent =
        "Downloading selected files";

    progressBytes.textContent =
        "0 B / unknown";

    progressBar.style.width =
        "0%";

    progressBar.classList.remove(
        "progress-complete"
    );

    progressPercent.textContent =
        "Receiving...";

    const xhr =
        new XMLHttpRequest();

    xhr.open(
        "POST",
        "/download-multiple",
        true
    );

    xhr.responseType =
        "blob";

    xhr.setRequestHeader(
        "X-Auth-Token",
        authToken
    );

    xhr.setRequestHeader(
        "Content-Type",
        "application/json"
    );

    xhr.onprogress =
        function(event) {

            if (event.lengthComputable) {

                const percent =
                    Math.min(
                        100,
                        Math.round(
                            (event.loaded /
                             event.total) * 100
                        )
                    );

                progressBar.style.width =
                    percent + "%";

                progressPercent.textContent =
                    percent + "%";

                progressBytes.textContent =
                    formatBytes(event.loaded) +
                    " / " +
                    formatBytes(event.total);
            }
            else {

                progressBytes.textContent =
                    formatBytes(event.loaded) +
                    " / unknown";

                progressPercent.textContent =
                    "Receiving...";
            }
        };

    xhr.onload =
        function() {

            if (
                xhr.status < 200 ||
                xhr.status >= 300
            ) {

                progressName.textContent =
                    "ZIP download failed";

                alert(
                    "Multiple download failed."
                );

                return;
            }

            progressBar.style.width =
                "100%";

            progressPercent.textContent =
                "100%";

            progressBar.classList.add(
                "progress-complete"
            );

            progressBytes.textContent =
                formatBytes(
                    xhr.response.size
                ) +
                " / " +
                formatBytes(
                    xhr.response.size
                );

            status.textContent =
                "ZIP download complete.";

            const url =
                URL.createObjectURL(
                    xhr.response
                );

            const a =
                document.createElement(
                    "a"
                );

            a.href = url;

            a.download =
                "intranet-download.zip";

            document.body.appendChild(a);
            a.click();
            a.remove();

            setTimeout(
                function() {
                    URL.revokeObjectURL(url);
                },
                1000
            );
        };

    xhr.onerror =
        function() {

            progressName.textContent =
                "ZIP download failed";

            alert(
                "Network error while downloading."
            );
        };

    xhr.send(
        JSON.stringify(selected)
    );
}


// ========================================================
// MULTIPLE UPLOAD
// ========================================================


async function uploadFiles() {

    const input =
        document.getElementById(
            "uploadFiles"
        );

    const files =
        Array.from(
            input.files
        );

    if (
        files.length === 0
    ) {

        alert(
            "Select files first."
        );

        return;
    }

    const status =
        document.getElementById(
            "uploadStatus"
        );

    const progressName =
        document.getElementById(
            "uploadProgressName"
        );

    const progressBytes =
        document.getElementById(
            "uploadProgressBytes"
        );

    const progressBar =
        document.getElementById(
            "uploadProgressBar"
        );

    const progressPercent =
        document.getElementById(
            "uploadProgressPercent"
        );

    status.textContent =
        "Starting uploads...";

    for (
        let index = 0;
        index < files.length;
        index++
    ) {

        const file =
            files[index];

        status.textContent +=
            "\n\nUploading (" +
            (index + 1) +
            "/" +
            files.length +
            "): " +
            file.name;

        progressName.textContent =
            "Uploading: " +
            file.name;

        progressBytes.textContent =
            "0 B / " +
            formatBytes(file.size);

        progressBar.style.width =
            file.size === 0
                ? "100%"
                : "0%";

        progressBar.classList.remove(
            "progress-complete"
        );

        progressPercent.textContent =
            file.size === 0
                ? "100%"
                : "0%";

        try {

            const result =
                await new Promise(
                    function(resolve, reject) {

                        const xhr =
                            new XMLHttpRequest();

                        xhr.open(
                            "POST",
                            "/upload",
                            true
                        );

                        xhr.setRequestHeader(
                            "X-Auth-Token",
                            authToken
                        );

                        xhr.setRequestHeader(
                            "X-Filename",
                            file.name
                        );

                        xhr.setRequestHeader(
                            "Content-Type",
                            "application/octet-stream"
                        );

                        xhr.upload.onprogress =
                            function(event) {

                                if (
                                    !event.lengthComputable
                                ) {

                                    progressBytes.textContent =
                                        "Sent " +
                                        formatBytes(
                                            event.loaded
                                        ) +
                                        " / " +
                                        formatBytes(
                                            file.size
                                        );

                                    progressPercent.textContent =
                                        "Uploading...";

                                    return;
                                }

                                const percent =
                                    file.size === 0
                                        ? 100
                                        : Math.min(
                                            100,
                                            Math.round(
                                                (event.loaded /
                                                 event.total) *
                                                100
                                            )
                                        );

                                progressBar.style.width =
                                    percent + "%";

                                progressPercent.textContent =
                                    percent + "%";

                                progressBytes.textContent =
                                    formatBytes(
                                        event.loaded
                                    ) +
                                    " / " +
                                    formatBytes(
                                        event.total
                                    );
                            };

                        xhr.onload =
                            function() {

                                if (
                                    xhr.status < 200 ||
                                    xhr.status >= 300
                                ) {

                                    reject(
                                        new Error(
                                            xhr.responseText ||
                                            "Upload failed."
                                        )
                                    );

                                    return;
                                }

                                try {

                                    resolve(
                                        JSON.parse(
                                            xhr.responseText
                                        )
                                    );

                                }
                                catch (_) {

                                    reject(
                                        new Error(
                                            "Invalid server response."
                                        )
                                    );
                                }
                            };

                        xhr.onerror =
                            function() {

                                reject(
                                    new Error(
                                        "Network error while uploading."
                                    )
                                );
                            };

                        xhr.onabort =
                            function() {

                                reject(
                                    new Error(
                                        "Upload cancelled."
                                    )
                                );
                            };

                        xhr.send(file);
                    }
                );

            progressBar.style.width =
                "100%";

            progressPercent.textContent =
                "100%";

            progressBar.classList.add(
                "progress-complete"
            );

            progressBytes.textContent =
                formatBytes(
                    result.size
                ) +
                " / " +
                formatBytes(
                    file.size
                );

            status.textContent +=
                " -> OK (" +
                formatBytes(
                    result.size
                ) +
                ")";

        }
        catch (
            error
        ) {

            progressBar.classList.remove(
                "progress-complete"
            );

            progressName.textContent =
                "Upload failed: " +
                file.name;

            status.textContent +=
                " -> ERROR: " +
                error.message;
        }
    }

    progressName.textContent =
        "All uploads finished";

    progressPercent.textContent =
        "100%";

    status.textContent +=
        "\n\nAll uploads finished.";

    input.value = "";

    refreshFiles();
}

</script>

</body>

</html>
'@

# =============================================================
# MAIN TUI
# =============================================================

function Show-MainMenu {

    while ($true) {

        Update-ServerState

        Clear-TUI

        Write-Host ""
        Write-Host `
            "====================================================" `
            -ForegroundColor Cyan

        Write-Host `
            "           INTRANET FILE SERVER / TUI" `
            -ForegroundColor Cyan

        Write-Host `
            "====================================================" `
            -ForegroundColor Cyan

        Write-Host ""

        Write-Host `
            "SERVER STATUS: " `
            -NoNewline

        if ($Global:ServerRunning) {

            Write-Host `
                "RUNNING" `
                -ForegroundColor Green
        }
        else {

            Write-Host `
                "STOPPED" `
                -ForegroundColor Red
        }

        Write-Host ""

        Write-Host `
            "Shared folder:"

        Write-Host `
            "  $($Config.Root)" `
            -ForegroundColor Yellow

        Write-Host ""

        Write-Host `
            "Port:"

        Write-Host `
            "  $($Config.Port)" `
            -ForegroundColor Yellow

        Write-Host ""

        Write-Host `
            "Upload limit:"

        Write-Host `
            "  $($Config.MaxUploadMB) MB" `
            -ForegroundColor Yellow

        Write-Host ""

        Write-Host `
            "----------------------------------------------------"

        Write-Host `
            "1. Start server"

        Write-Host `
            "2. Stop server"

        Write-Host `
            "3. Server information"

        Write-Host `
            "4. Change token/password"

        Write-Host `
            "5. Change port"

        Write-Host `
            "6. Change shared folder"

        Write-Host `
            "7. Change upload limit"

        Write-Host `
            "8. Add firewall rule"

        Write-Host `
            "9. Save configuration"

        Write-Host ""

        Write-Host `
            "Q. Quit"

        Write-Host `
            "----------------------------------------------------"

        Write-Host ""

        $Choice =
            Read-Host `
                "Select option"

        # =====================================================
        # EACH OPTION RETURNS HERE
        # =====================================================

        switch (
            $Choice.ToUpperInvariant()
        ) {

            "1" {

                Start-FileServer
            }

            "2" {

                Stop-FileServer
            }

            "3" {

                Show-ServerInfo
            }

            "4" {

                Change-Token
            }

            "5" {

                Change-Port
            }

            "6" {

                Change-Root
            }

            "7" {

                Change-MaxUpload
            }

            "8" {

                Add-IntranetFirewallRule
            }

            "9" {

                Save-ConfigurationMenu
            }

            "Q" {

                Stop-FileServer

                Clear-TUI

                Write-Host ""

                Write-Host `
                    "Intranet File Server closed." `
                    -ForegroundColor Yellow

                return
            }

            default {

                Write-Host ""

                Write-Host `
                    "Invalid option." `
                    -ForegroundColor Red

                Start-Sleep `
                    -Milliseconds 700
            }
        }

        # =====================================================
        # IMPORTANT
        #
        # There is intentionally NO "break" here.
        #
        # The while loop redraws the main menu automatically.
        # =====================================================
    }
}

# =============================================================
# PROGRAM ENTRY
# =============================================================

try {

    Show-MainMenu
}
catch {

    Write-Host ""

    Write-Host `
        "Fatal error:" `
        -ForegroundColor Red

    Write-Host `
        $_.Exception.Message `
        -ForegroundColor Red

    Write-Host ""

    Pause-TUI
}
finally {

    Stop-FileServer

    [Console]::CursorVisible = $true
}
