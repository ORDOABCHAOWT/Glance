# clt-swift-env.sh - workarounds for building macOS apps with Command Line Tools only.
#
# Source this file from a zsh build script; it defines helpers and runs nothing.
# It is copied verbatim into every repository that needs it (no cross-repository
# dependency). CI checks it against scripts/clt-swift-env.sh.sha256, so after an
# edit regenerate the checksum and copy both files to the other repositories:
#
#   (cd scripts && shasum -a 256 clt-swift-env.sh > clt-swift-env.sh.sha256)
#
# Two traps exist on a Mac that has Command Line Tools 27 but no Xcode:
#
# 1. The macOS 27 SDK declares SwiftUI's @State as a macro implemented by the
#    SwiftUIMacros plugin, which only Xcode ships. SwiftUI apps must build against
#    the newest installed SDK that still declares @State as a property wrapper.
#    -> clt_select_swiftui_sdk (call it only from SwiftUI apps)
#
# 2. swiftbuild, SwiftPM's default build system since Swift 6.4, links with the
#    deployment target as the SDK version (for example "sdk 12.0"), which opts
#    the app out of current macOS behaviour. The native build system records the
#    real SDK version.
#    -> CLT_SWIFT_BUILD_SYSTEM_ARGS (pass it to every `swift build` invocation,
#       including `--show-bin-path`, because the output directory differs)
#    -> clt_check_sdk_stamp <binary> (fails when the stamp is still wrong)
#
# With a full Xcode (for example on GitHub runners) every helper is a no-op or a
# plain report.

clt_swiftui_state_is_macro() {
    grep -qs 'type: "StateMacro"' \
        "$1/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
}

# Exports SDKROOT when the default SDK needs the SwiftUIMacros plugin and the
# toolchain does not ship it. Leaves an SDKROOT chosen by the caller alone.
clt_select_swiftui_sdk() {
    [[ -z "${SDKROOT:-}" ]] || return 0

    local default_sdk swiftc_path candidate
    default_sdk="$(xcrun --sdk macosx --show-sdk-path)"
    swiftc_path="$(xcrun --find swiftc)"

    clt_swiftui_state_is_macro "$default_sdk" || return 0
    [[ ! -e "${swiftc_path:h:h}/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]] || return 0

    for candidate in "${default_sdk:h}"/MacOSX<->.<->.sdk(NnOn); do
        if ! clt_swiftui_state_is_macro "$candidate"; then
            export SDKROOT="$candidate"
            echo "clt-swift-env: the default SDK needs Xcode's SwiftUIMacros plugin; building against ${candidate:t}"
            return 0
        fi
    done

    echo "clt-swift-env: no installed macOS SDK declares @State without the SwiftUIMacros plugin" >&2
    return 1
}

# `--build-system native` wherever SwiftPM still offers it; empty otherwise.
typeset -ga CLT_SWIFT_BUILD_SYSTEM_ARGS
CLT_SWIFT_BUILD_SYSTEM_ARGS=()
if swift build --help 2>/dev/null | grep -Eq '^[[:space:]]+native[[:space:]]'; then
    CLT_SWIFT_BUILD_SYSTEM_ARGS=(--build-system native)
fi

# Prints the LC_BUILD_VERSION stamp of a Mach-O binary and fails when the SDK
# version equals the deployment target although the SDK in use is a different
# version, which is the swiftbuild symptom described above.
clt_check_sdk_stamp() {
    local binary="$1" stamp minos sdk sdk_root sdk_version
    stamp="$(otool -l "$binary" | grep -A5 LC_BUILD_VERSION)"
    minos="$(echo "$stamp" | awk '$1 == "minos" { print $2; exit }')"
    sdk="$(echo "$stamp" | awk '$1 == "sdk" { print $2; exit }')"
    sdk_root="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
    sdk_version="$(/usr/libexec/PlistBuddy -c 'Print :Version' "$sdk_root/SDKSettings.plist" 2>/dev/null || true)"

    echo "clt-swift-env: ${binary:t} minos $minos, sdk $sdk (SDK in use: ${sdk_version:-unknown})"

    if [[ -n "$sdk_version" && "$sdk" == "$minos" && "$sdk" != "$sdk_version" && "$sdk.0" != "$sdk_version" ]]; then
        echo "clt-swift-env: the SDK version was stamped as the deployment target; build with --build-system native" >&2
        return 1
    fi
}
