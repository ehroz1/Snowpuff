#!/bin/zsh
# Builds build/Snowpuff.app for Apple silicon and Intel Macs, signed ad hoc.
# ./build.sh install  — also copies it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)
export MACOSX_DEPLOYMENT_TARGET="$minimum"

# The Rust the app links, for both architectures in one library: the rooms for snowball fights (net/) and Snowpuff's
# extras, icicles and sounds (core/), through bridge/.
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    cargo build --quiet --release --manifest-path bridge/Cargo.toml --target "$target"
done
mkdir -p build/rust
lipo -create bridge/target/{aarch64,x86_64}-apple-darwin/release/libsnowpuff_mac.a -output build/rust/libsnowpuff_mac.a

# One build per architecture, joined into one binary: a universal build needs Xcode, separate ones don't.
binaries=()
for arch in arm64 x86_64; do
    # SwiftPM doesn't see the Rust library change, so the app is always linked afresh.
    rm -f "$(swift build -c release --arch $arch --show-bin-path)/Snowpuff"
    swift build -c release --arch $arch
    binaries+=("$(swift build -c release --arch $arch --show-bin-path)/Snowpuff")
done

app=build/Snowpuff.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "${binaries[@]}" -output build/Snowpuff-universal
# Swift Build stamps the binary with the deployment target as its SDK, and macOS then draws the app in its old
# look, without Liquid Glass.
vtool -set-build-version macos "$minimum" "$(xcrun --sdk macosx --show-sdk-version)" -replace \
    -output "$app/Contents/MacOS/Snowpuff" build/Snowpuff-universal 2>/dev/null \
    || cp build/Snowpuff-universal "$app/Contents/MacOS/Snowpuff"
# Local symbols serve only a debugger; without them the app is several megabytes lighter.
strip -x "$app/Contents/MacOS/Snowpuff"
cp Resources/Info.plist "$app/Contents/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
# Snowpuff's extras are drawn by shaders shared with Windows.
cp shaders/extras.shader "$app/Contents/Resources/"

# The depth network that finds the tops of things in the wallpaper for snow to lie on: Apple's Core ML conversion of
# Depth Anything V2 Small, palettized to 6 bits (Apache-2.0). Fetched once at a fixed revision, checked, compiled.
model=DepthAnythingV2SmallF16P6
models=build/models
if [[ ! -d "$models/$model.mlmodelc" ]]; then
    revision=cfef6f6f2a70783dedc0bfae40cecbc2052285d3
    base="https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/$revision/$model.mlpackage"
    package="$models/$model.mlpackage"
    while read -r sum file; do
        mkdir -p "$package/${file:h}"
        curl -sfL --retry 3 -o "$package/$file" "$base/$file"
        echo "$sum  $package/$file" | shasum -a 256 -c --quiet
    done <<'FILES'
70e469c0359c89851bde4cdc1d89bf13fa06d4fccd8907b9b5f744e548ecaadf Manifest.json
ee53b8f7e1682a66857b5a3d54cf04a97d89a98cf7b5979b5d726aaf9c24ad70 Data/com.apple.CoreML/model.mlmodel
3e9bcccc9e35ae6f9759551f481a3b77226510bd74536e059ee9780dda618381 Data/com.apple.CoreML/weights/weight.bin
FILES
    if xcrun --find coremlcompiler >/dev/null 2>&1; then
        xcrun coremlcompiler compile "$package" "$models" >/dev/null
    else
        swift scripts/compile-model.swift "$package" "$models"
    fi
fi
ditto "$models/$model.mlmodelc" "$app/Contents/Resources/$model.mlmodelc"
cp Resources/ThirdParty/DepthAnything-LICENSE.txt "$app/Contents/Resources/"
cp Resources/ThirdParty/Mac-Notices.txt "$app/Contents/Resources/ThirdPartyNotices.txt"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
for strings in locales/*.strings; do
    lproj="$app/Contents/Resources/$(basename "$strings" .strings).lproj"
    mkdir -p "$lproj"
    plutil -convert binary1 -o "$lproj/Localizable.strings" "$strings"
done
printf '"NSMicrophoneUsageDescription" = "Snowpuff слушает микрофон только чтобы заметить, что ты дуешь на снег. Ничего не записывается и никуда не отправляется.";\n"NSLocationUsageDescription" = "«Погода за окном» включает снег или дождь, как у тебя на улице. Место округляется и нужно только чтобы узнать погоду на open-meteo.com.";\n"NSLocationWhenInUseUsageDescription" = "«Погода за окном» включает снег или дождь, как у тебя на улице. Место округляется и нужно только чтобы узнать погоду на open-meteo.com.";\n' > "$app/Contents/Resources/ru.lproj/InfoPlist.strings"

codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Snowpuff 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Snowpuff.app
    ditto "$app" /Applications/Snowpuff.app
    open /Applications/Snowpuff.app
    echo "Installed /Applications/Snowpuff.app"
fi
