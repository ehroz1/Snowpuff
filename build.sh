#!/bin/zsh
# Builds build/Snowpuff.app for Apple silicon and Intel Macs, signed ad hoc.
# ./build.sh install  — also copies it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

# The Rust core, which the app links, for both architectures in one library.
export MACOSX_DEPLOYMENT_TARGET=14.0
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    (cd core && cargo build --release --lib --target $target)
done
mkdir -p core/target/universal
lipo -create core/target/aarch64-apple-darwin/release/libsnowpuff_core.a core/target/x86_64-apple-darwin/release/libsnowpuff_core.a \
    -output core/target/universal/libsnowpuff_core.a

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
lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/Snowpuff"
cp Resources/Info.plist "$app/Contents/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp Resources/TrayIcon*.png "$app/Contents/Resources/"
cp shaders/extras.shader "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/ru.lproj" "$app/Contents/Resources/en.lproj"
printf '"NSMicrophoneUsageDescription" = "Snowpuff слушает микрофон только чтобы заметить, что ты дуешь на снег. Ничего не записывается и никуда не отправляется.";\n"NSLocationUsageDescription" = "«Погода за окном» включает снег или дождь, как у тебя на улице. Место округляется и нужно только чтобы узнать погоду на open-meteo.com.";\n"NSLocationWhenInUseUsageDescription" = "«Погода за окном» включает снег или дождь, как у тебя на улице. Место округляется и нужно только чтобы узнать погоду на open-meteo.com.";\n' > "$app/Contents/Resources/ru.lproj/InfoPlist.strings"
printf '"NSMicrophoneUsageDescription" = "Snowpuff listens for a puff of breath so you can blow on the snow. Nothing is recorded or sent anywhere.";\n' > "$app/Contents/Resources/en.lproj/InfoPlist.strings"

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
