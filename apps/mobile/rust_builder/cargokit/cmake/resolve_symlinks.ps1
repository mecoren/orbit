function Resolve-Symlinks {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0, Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string] $Path
    )

    [string] $separator = '/'
    [string[]] $parts = $Path.Split($separator)

    [string] $realPath = ''
    foreach ($part in $parts) {
        if ($realPath -and !$realPath.EndsWith($separator)) {
            $realPath += $separator
        }

        $realPath += $part.Replace('\', '/')

        # The slash is important when using Get-Item on Drive letters in pwsh.
        if (-not($realPath.Contains($separator)) -and $realPath.EndsWith(':')) {
            $realPath += '/'
        }

        # Get-Item follows the symlink and returns the real item, so to detect
        # whether the *current* path segment is a symlink we must resolve the
        # symbolic link itself (which Get-Item does not for the final segment).
        # Use the reparse-point aware lookup.
        try {
            $item = Get-Item -LiteralPath $realPath -Force
        } catch {
            $item = $null
        }

        if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            # Windows PowerShell 5.1 exposes the target via .Target, while
            # PowerShell (Core) 6+ exposes it via .LinkTarget. Support both.
            [string] $linkTarget = $null
            if ($item.LinkTarget) {
                $linkTarget = $item.LinkTarget
            } elseif ($item.Target) {
                $linkTarget = @($item.Target)[0]
            }

            if ($linkTarget) {
                $lt = $linkTarget.Replace('\', '/')
                # Resolve relative targets against the symlink's parent directory.
                if (-not [System.IO.Path]::IsPathRooted($lt)) {
                    $parent = Split-Path -Parent $realPath
                    $lt = (Join-Path $parent $lt).Replace('\', '/')
                }
                $realPath = $lt
            }
        }
    }
    $realPath
}

$path = Resolve-Symlinks -Path $args[0]
Write-Host $path
