@{
    WslPayloadRelativeDir = "app\resources"
    RequiredWslPayloads = @(
        "app\resources\codex"
        "app\resources\codex-resources\bwrap"
    )
    AllowedX64Fallbacks = @(
        "app\resources\cua_node\bin\node_repl.exe"
        "app\resources\plugins\openai-bundled\plugins\latex\bin\tectonic.exe"
        "app\resources\plugins\openai-bundled\plugins\chrome\extension-host\windows\x64\extension-host.exe"
        "app\resources\plugins\openai-bundled\plugins\chrome\extension-host\windows\arm64\extension-host.exe"
        "app\resources\cua_node\bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe"
        "app\resources\native\computer-use-app-icons.node"
    )
}
