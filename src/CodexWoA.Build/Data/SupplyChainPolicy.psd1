@{
    StoreSource = @{
        ExpectedIdentityName = "OpenAI.Codex"
        ExpectedArchitecture = "x64"
        ExpectedPublisher = "CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B"
        RequiredSignerIssuerContains = "Microsoft Marketplace CA"
        AllowedUrlHosts = @(
            "tlu.dl.delivery.mp.microsoft.com"
        )
    }

    GitHubReleases = @{
        Electron = @{
            Owner = "electron"
            Repo = "electron"
            AllowPrerelease = $false
            AssetNamePattern = "^electron-v\d+\.\d+\.\d+-win32-arm64\.zip$"
        }
        Codex = @{
            Owner = "openai"
            Repo = "codex"
            AllowPrerelease = $false
            AssetNamePattern = "^(codex|bwrap).+-(pc-windows-msvc|unknown-linux-musl)(\.exe|\.tar\.gz)$"
        }
        Ripgrep = @{
            Owner = "BurntSushi"
            Repo = "ripgrep"
            AllowPrerelease = $false
            AssetNamePattern = "^ripgrep-\d+\.\d+\.\d+-aarch64-pc-windows-msvc\.zip$"
        }
    }

    DirectDownloads = @{
        Rcedit = @{
            Version = "v2.0.0"
            AssetName = "rcedit-x64.exe"
            Url = "https://github.com/electron/rcedit/releases/download/v2.0.0/rcedit-x64.exe"
            Sha256 = "3E7801DB1A5EDBEC91B49A24A094AAD776CB4515488EA5A4CA2289C400EADE2A"
        }
    }

    Node = @{
        ChecksumsFile = "SHASUMS256.txt.asc"
        RequireSignedChecksums = $true
        ReleaseKeysRepo = "https://github.com/nodejs/release-keys.git"
        ReleaseKeysRef = "main"
        ReleaseKeysGpgDirectory = "gpg"
    }
}
