#requires -Version 5.1
<#
.SYNOPSIS
    Run kokotaro/narou with WSL containers (wslc.exe).
.EXAMPLE
    .\narou.ps1
.EXAMPLE
    .\narou.ps1 Start -DataDir 'F:\My Novels' -Port 9300 -WebSocketPort 9301
.EXAMPLE
    .\narou.ps1 Stop
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Start', 'Stop', 'Status', 'Logs', 'Pull', 'Fetch', 'FixCertificates', 'Remove')]
    [string]$Action = 'Start',

    [string]$Image = 'kokotaro/narou:latest',
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')]
    [string]$Name = 'narou-wslc',
    [string]$DataDir = '',
    [ValidateRange(1, 65535)]
    [int]$Port = 9200,
    [ValidateRange(1, 65535)]
    [int]$WebSocketPort = 9201,
    [switch]$OpenBrowser = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Native failures are checked explicitly for both Windows PowerShell and PS 7.
$PSNativeCommandUseErrorActionPreference = $false
$managerLabel = 'local.narou-wslc.managed'

function Invoke-Wslc {
    param([string[]]$Arguments)
    & $script:wslcPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "wslc $($Arguments[0]) failed (exit code $LASTEXITCODE)."
    }
}

function Get-NarouContainer {
    # Check the runtime first; do not mistake a runtime failure for a missing container.
    $ids = @(Invoke-Wslc -Arguments @('container', 'list', '--all', '--quiet'))
    if ($ids.Count -eq 0) { return $null }

    $objects = Invoke-Wslc -Arguments (@('inspect', '--type', 'container') + $ids)
    $containers = @((($objects -join "`n") | ConvertFrom-Json))
    $found = @($containers | Where-Object { $_.Name.TrimStart('/') -eq $Name })
    if ($found.Count -eq 0) { return $null }
    $container = $found[0]
    # WSLc can expose explicitly supplied labels at the top level.
    $labels = $null
    if ($container.PSObject.Properties.Name -contains 'Labels') {
        $labels = $container.Labels
    }
    elseif ($container.Config.PSObject.Properties.Name -contains 'Labels') {
        $labels = $container.Config.Labels
    }
    if ($null -eq $labels -or
        $labels.PSObject.Properties.Name -notcontains $managerLabel -or
        $labels.$managerLabel -ne 'true') {
        throw "Container '$Name' was not created by this script. Choose another -Name."
    }
    return $container
}

function Save-NarouImageArchive {
    [CmdletBinding()]
    param(
        [ValidatePattern('^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$')]
        [string]$Tag = 'latest',
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $utf8 = New-Object Text.UTF8Encoding($false)
    $repo = 'kokotaro/narou'
    $registry = "https://registry-1.docker.io/v2/$repo"

    function Receive-ImageFile {
        param([string]$Uri, [string]$Destination, [hashtable]$Headers = @{})
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $response = $null; $inputStream = $null; $outputStream = $null
            try {
                $request = [Net.HttpWebRequest]::Create($Uri)
                $request.Timeout = 60000
                $request.ReadWriteTimeout = 60000
                foreach ($key in $Headers.Keys) {
                    if ($key -eq 'Accept') { $request.Accept = $Headers[$key] }
                    else { $request.Headers[$key] = $Headers[$key] }
                }
                # .NET clears Authorization on cross-host redirects to the blob CDN.
                $response = $request.GetResponse()
                $inputStream = $response.GetResponseStream()
                $outputStream = [IO.File]::Create($Destination)
                $inputStream.CopyTo($outputStream, 1048576)
                return
            }
            catch {
                if ($attempt -eq 3) { throw }
                Write-Host "Download attempt $attempt failed. Retrying..."
                Start-Sleep -Seconds 2
            }
            finally {
                if ($null -ne $outputStream) { $outputStream.Dispose() }
                if ($null -ne $inputStream) { $inputStream.Dispose() }
                if ($null -ne $response) { $response.Close() }
            }
        }
    }

    function Assert-ImageDigest {
        param([string]$Path, [string]$Digest)
        if ($Digest -notmatch '^sha256:[a-fA-F0-9]{64}$') { throw 'Unsupported image digest.' }
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Digest.Substring(7)) {
            throw "SHA256 mismatch: $([IO.Path]::GetFileName($Path))"
        }
    }

    function Write-TarField {
        param([byte[]]$Header, [int]$Offset, [int]$Length, [string]$Value)
        $bytes = [Text.Encoding]::ASCII.GetBytes($Value)
        if ($bytes.Length -gt $Length) { throw 'Tar header field is too long.' }
        [Array]::Copy($bytes, 0, $Header, $Offset, $bytes.Length)
    }

    function Write-ImageTar {
        param([string]$Directory, [string[]]$Names, [string]$Destination)
        $archive = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew)
        try {
            foreach ($name in $Names) {
                $source = [IO.File]::OpenRead((Join-Path $Directory $name))
                try {
                    # USTAR regular files with generated ASCII names shorter than 100 bytes.
                    $header = New-Object byte[] 512
                    Write-TarField $header 0 100 $name
                    Write-TarField $header 100 8 '0000644'
                    Write-TarField $header 108 8 '0000000'
                    Write-TarField $header 116 8 '0000000'
                    $sizeOctal = [Convert]::ToString([long]$source.Length, 8).PadLeft(11, '0')
                    Write-TarField $header 124 11 $sizeOctal
                    Write-TarField $header 136 12 '00000000000'
                    for ($i = 148; $i -lt 156; $i++) { $header[$i] = 32 }
                    $header[156] = 48
                    Write-TarField $header 257 6 "ustar`0"
                    Write-TarField $header 263 2 '00'
                    Write-TarField $header 265 32 'root'
                    Write-TarField $header 297 32 'root'
                    $checksum = 0
                    foreach ($byte in $header) { $checksum += [int]$byte }
                    Write-TarField $header 148 8 ([Convert]::ToString($checksum, 8).PadLeft(6, '0') + "`0 ")
                    $archive.Write($header, 0, 512)
                    $source.CopyTo($archive, 1048576)
                    $padding = [int]((512 - ($source.Length % 512)) % 512)
                    if ($padding -gt 0) { $archive.Write((New-Object byte[] $padding), 0, $padding) }
                }
                finally { $source.Dispose() }
            }
            $archive.Write((New-Object byte[] 1024), 0, 1024)
        }
        finally { $archive.Dispose() }
    }

    $fullOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $outputDir = Split-Path -Parent $fullOutput
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    $work = Join-Path $outputDir ('.narou-fetch-' + [Guid]::NewGuid().ToString('N'))
    $partial = Join-Path $work 'image.partial'
    $previousTls = [Net.ServicePointManager]::SecurityProtocol
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
        $machine = $env:PROCESSOR_ARCHITEW6432
        if ([string]::IsNullOrEmpty($machine)) { $machine = $env:PROCESSOR_ARCHITECTURE }
        $architecture = switch ($machine) {
            'AMD64' { 'amd64' }
            'ARM64' { 'arm64' }
            default { throw "Unsupported host architecture: $machine" }
        }
        $tokenPath = Join-Path $work 'token.json'
        $scope = [Uri]::EscapeDataString("repository:${repo}:pull")
        Receive-ImageFile "https://auth.docker.io/token?service=registry.docker.io&scope=$scope" $tokenPath
        $token = ([IO.File]::ReadAllText($tokenPath) | ConvertFrom-Json).token
        $headers = @{
            Authorization = "Bearer $token"
            Accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
        }
        $manifestPath = Join-Path $work 'remote-manifest.json'
        Receive-ImageFile "$registry/manifests/$Tag" $manifestPath $headers
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        if ($manifest.PSObject.Properties.Name -contains 'manifests') {
            $platformManifests = @($manifest.manifests | Where-Object {
                $_.PSObject.Properties.Name -contains 'platform' -and
                $_.platform.os -eq 'linux' -and $_.platform.architecture -eq $architecture
            })
            if ($platformManifests.Count -eq 0) { throw "The image has no linux/$architecture manifest." }
            $digest = $platformManifests[0].digest
            Receive-ImageFile "$registry/manifests/$digest" $manifestPath $headers
            Assert-ImageDigest $manifestPath $digest
            $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        }
        $configDigest = $manifest.config.digest
        if ($configDigest -notmatch '^sha256:[a-fA-F0-9]{64}$') { throw 'Invalid config digest.' }
        $configName = $configDigest.Substring(7) + '.json'
        $configPath = Join-Path $work $configName
        Receive-ImageFile "$registry/blobs/$configDigest" $configPath $headers
        Assert-ImageDigest $configPath $configDigest
        $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
        if ($config.os -ne 'linux' -or $config.architecture -ne $architecture) { throw 'Image platform mismatch.' }
        if ($config.rootfs.diff_ids.Count -ne $manifest.layers.Count) { throw 'Image layer count mismatch.' }
        $layerNames = [Collections.Generic.List[string]]::new()
        for ($index = 0; $index -lt $manifest.layers.Count; $index++) {
            $layer = $manifest.layers[$index]
            Write-Host ('Downloading layer {0}/{1} ({2:F1} MB)...' -f ($index + 1), $manifest.layers.Count, ($layer.size / 1MB))
            $blob = Join-Path $work 'download.blob'
            Receive-ImageFile "$registry/blobs/$($layer.digest)" $blob $headers
            Assert-ImageDigest $blob $layer.digest
            $layerName = '{0:D3}/layer.tar' -f $index
            $layerPath = Join-Path $work $layerName
            New-Item -ItemType Directory -Path (Split-Path -Parent $layerPath) | Out-Null
            if ($layer.mediaType.EndsWith('gzip')) {
                $compressed = [IO.File]::OpenRead($blob)
                $expanded = $null; $gzip = $null
                try {
                    $gzip = [IO.Compression.GZipStream]::new($compressed, [IO.Compression.CompressionMode]::Decompress)
                    $expanded = [IO.File]::Create($layerPath)
                    $gzip.CopyTo($expanded, 1048576)
                }
                finally {
                    if ($null -ne $expanded) { $expanded.Dispose() }
                    if ($null -ne $gzip) { $gzip.Dispose() }
                    $compressed.Dispose()
                }
            }
            elseif ($layer.mediaType.EndsWith('.tar')) { [IO.File]::Copy($blob, $layerPath) }
            else { throw "Unsupported layer compression: $($layer.mediaType)" }
            Assert-ImageDigest $layerPath $config.rootfs.diff_ids[$index]
            Remove-Item -LiteralPath $blob
            $layerNames.Add($layerName)
        }
        $saveManifest = @([ordered]@{ Config = $configName; RepoTags = @("${repo}:$Tag"); Layers = $layerNames.ToArray() })
        $saveJson = ConvertTo-Json -InputObject $saveManifest -Depth 5 -Compress
        [IO.File]::WriteAllText((Join-Path $work 'manifest.json'), $saveJson, $utf8)
        Write-Host 'Creating image archive...'
        Write-ImageTar $work (@('manifest.json', $configName) + $layerNames.ToArray()) $partial
        Move-Item -LiteralPath $partial -Destination $fullOutput -Force
        Write-Host "Saved: $fullOutput"
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls
        # Verify the generated cleanup target stays inside the intended output directory.
        $resolvedWork = [IO.Path]::GetFullPath($work)
        $resolvedParent = [IO.Path]::GetFullPath($outputDir).TrimEnd('\') + '\'
        if (-not $resolvedWork.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolvedWork) -notmatch '^\.narou-fetch-[a-f0-9]{32}$') {
            throw 'Refusing to clean up an unexpected temporary directory.'
        }
        if (Test-Path -LiteralPath $resolvedWork) { Remove-Item -LiteralPath $resolvedWork -Recurse -Force }
    }
}

function Fetch-NarouImage {
    if ($Image -notmatch '^kokotaro/narou:([a-zA-Z0-9_][a-zA-Z0-9_.-]*)$') {
        throw 'Fetch supports only kokotaro/narou:<tag>.'
    }
    $tag = $Matches[1]
    $archivePath = Join-Path $PSScriptRoot "narou-image-$tag.tar"
    Save-NarouImageArchive -Tag $tag -OutputPath $archivePath
    Invoke-Wslc -Arguments @('load', '--input', $archivePath) | Out-Host
    Write-Host 'Image loaded into WSLc.'
}

function Get-NarouWebUrl {
    param($Container)
    # Read the actual mapping when reusing a container created with a custom port.
    $ports = if ($Container.PSObject.Properties.Name -contains 'Ports') {
        $Container.Ports
    }
    else { $Container.NetworkSettings.Ports }
    $bindings = @($ports.'33000/tcp')
    if ($bindings.Count -eq 0 -or $null -eq $bindings[0]) {
        throw 'The container has no published Web UI port. Check Status.'
    }
    $hostPort = [int]$bindings[0].HostPort
    if ($hostPort -lt 1 -or $hostPort -gt 65535) { throw 'Invalid Web UI host port.' }
    return "http://localhost:$hostPort/"
}

function Wait-NarouWeb {
    param([string]$Url, [int]$TimeoutSeconds = 30)
    # Published ports bind to IPv4; .NET Framework can stall on localhost's IPv6 address.
    $probeUrl = $Url -replace '^http://localhost:', 'http://127.0.0.1:'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $response = $null
        try {
            $request = [Net.HttpWebRequest]::Create($probeUrl)
            $request.Proxy = $null
            $request.Timeout = 2000
            $request.ReadWriteTimeout = 2000
            $response = $request.GetResponse()
            if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400) { return }
        }
        catch [Net.WebException] { }
        finally { if ($null -ne $response) { $response.Close() } }
        if ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) { Start-Sleep -Milliseconds 500 }
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "Web UI did not become ready within $TimeoutSeconds seconds: $Url. Check Logs."
}

function Sync-NortonCertificate {
    param($Container)
    # Import only the currently valid Norton inspection roots already trusted by Windows.
    # Never use a server-provided, unverified certificate as a trust anchor.
    $certificates = @(Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root |
        Where-Object {
            $_.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -eq 'Norton Web/Mail Shield Root' -and
            $_.Subject -eq $_.Issuer -and
            $_.NotBefore -le (Get-Date) -and $_.NotAfter -gt (Get-Date)
        } | Sort-Object Thumbprint -Unique)
    if ($certificates.Count -eq 0) { return $false }

    $mount = @($Container.Mounts | Where-Object {
        $_.Destination -eq '/home/narou/novel' -and $_.Type -eq 'bind'
    })
    if ($mount.Count -ne 1) { throw 'Cannot find the novel data bind mount for CA installation.' }
    $certDir = Join-Path $mount[0].Source '.ca-certificates'
    New-Item -ItemType Directory -Path $certDir -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    Invoke-Wslc -Arguments @('exec', '--user', 'root', $Name,
        'mkdir', '-p', '/usr/local/share/ca-certificates/narou-wslc') | Out-Host
    foreach ($certificate in $certificates) {
        $filename = "norton-$($certificate.Thumbprint).crt"
        $base64 = [Convert]::ToBase64String($certificate.RawData, [Base64FormattingOptions]::InsertLineBreaks)
        $pem = "-----BEGIN CERTIFICATE-----`n$base64`n-----END CERTIFICATE-----`n"
        [IO.File]::WriteAllText((Join-Path $certDir $filename), $pem, $utf8)
        Invoke-Wslc -Arguments @('exec', '--user', 'root', $Name, 'install', '-m', '0644',
            "/home/narou/novel/.ca-certificates/$filename",
            "/usr/local/share/ca-certificates/narou-wslc/$filename") | Out-Host
    }
    Invoke-Wslc -Arguments @('exec', '--user', 'root', $Name, 'update-ca-certificates') | Out-Host
    Write-Host 'Windows-trusted Norton CA installed. TLS certificate verification remains enabled.'
    return $true
}

try {
    if ([string]::IsNullOrWhiteSpace($DataDir)) {
        $DataDir = Join-Path $PSScriptRoot 'novel'
    }
    $wslcCommand = Get-Command wslc.exe -ErrorAction SilentlyContinue
    if ($null -eq $wslcCommand) {
        throw 'wslc.exe was not found. Install/update WSL with: wsl --update'
    }
    $script:wslcPath = $wslcCommand.Source

    if ($Action -eq 'Fetch') {
        Fetch-NarouImage
        Write-Host 'Run Start next.'
        exit 0
    }

    if ($Action -eq 'Pull') {
        Invoke-Wslc -Arguments @('pull', $Image)
        Write-Host 'Image downloaded. For recreation, use Remove, Pull (or Fetch), Start in that order.'
        exit 0
    }

    $container = Get-NarouContainer
    switch ($Action) {
        'Start' {
            if ($null -eq $container) {
                if ($Port -eq $WebSocketPort) { throw 'The two host ports must be different.' }
                $directory = New-Item -ItemType Directory -Path $DataDir -Force
                $dataPath = $directory.FullName
                if ($dataPath.Contains(',')) { throw 'DataDir cannot contain a comma (--mount syntax).' }
                $localImageIds = @(Invoke-Wslc -Arguments @(
                    'image', 'list', '--filter', "reference=$Image", '--quiet'
                ))
                if ($localImageIds.Count -eq 0) {
                    Write-Host "Image '$Image' is missing. Fetching via Windows before startup..."
                    Fetch-NarouImage
                }
                Invoke-Wslc -Arguments @(
                    'run', '--detach', '--interactive', '--tty',
                    '--pull', 'never',
                    '--name', $Name,
                    '--label', "${managerLabel}=true",
                    '--workdir', '/home/narou/novel',
                    '--mount', "type=bind,source=$dataPath,target=/home/narou/novel",
                    '--publish', "127.0.0.1:${Port}:33000",
                    '--publish', "127.0.0.1:${WebSocketPort}:33001",
                    $Image, 'narou', 'web', '-np', '33000'
                )
            }
            elseif (-not $container.State.Running) {
                Invoke-Wslc -Arguments @('start', $Name)
            }
            else {
                Write-Host "Container '$Name' is already running."
            }
            $runningContainer = Get-NarouContainer
            if (-not $runningContainer.State.Running) { throw 'Container exited during startup. Check Logs.' }
            Sync-NortonCertificate -Container $runningContainer | Out-Null
            if ($null -ne $container) {
                Write-Host 'Existing container settings are reused. Use Status to check its port and mount.'
            }
            else {
                Write-Host "Novel data: $dataPath"
            }
            $url = Get-NarouWebUrl -Container $runningContainer
            Write-Host "Waiting for Web UI: $url"
            Wait-NarouWeb -Url $url
            Write-Host "Web UI ready: $url"
            if ($OpenBrowser) { Start-Process $url }
        }
        'Status' {
            if ($null -eq $container) { Write-Host "Container '$Name' does not exist." }
            else { Invoke-Wslc -Arguments @('inspect', '--type', 'container', $Name) }
        }
        'Stop' {
            if ($null -ne $container -and $container.State.Running) {
                Invoke-Wslc -Arguments @('stop', $Name)
            }
            else { Write-Host "Container '$Name' is already stopped or does not exist." }
        }
        'Logs' {
            if ($null -eq $container) { throw "Container '$Name' does not exist. Run Start first." }
            Invoke-Wslc -Arguments @('logs', '--tail', '100', $Name)
        }
        'FixCertificates' {
            if ($null -eq $container -or -not $container.State.Running) {
                throw 'Run Start before FixCertificates.'
            }
            if (Sync-NortonCertificate -Container $container) {
                Invoke-Wslc -Arguments @('restart', $Name)
                Write-Host 'Certificates installed and web server restarted.'
            }
            else { throw 'No valid Norton inspection root was found in the Windows trusted root stores.' }
        }
        'Remove' {
            $imageToRemove = $Image
            if ($null -ne $container) {
                # Delete the exact image used by the container, even if its tag was updated.
                $imageToRemove = $container.Image
                if ($container.State.Running) { Invoke-Wslc -Arguments @('stop', $Name) }
                Invoke-Wslc -Arguments @('remove', $Name)
            }
            # Do not force deletion of an image shared with another container.
            Invoke-Wslc -Arguments @('rmi', $imageToRemove)
            Write-Host 'Container and image removed. Novel files and downloaded tar archives are preserved.'
        }
    }
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
