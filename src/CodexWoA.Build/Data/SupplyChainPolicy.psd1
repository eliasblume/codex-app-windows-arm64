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

    Node = @{
        ChecksumsFile = "SHASUMS256.txt.asc"
    }
}
