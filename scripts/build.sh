#!/bin/zsh
set -euo pipefail
project=${0:A:h:h}
export CLANG_MODULE_CACHE_PATH="$project/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$project/.cache/swift"
"$project/scripts/build-native.sh"
swift build --disable-sandbox --package-path "$project" --scratch-path "$project/.build" --cache-path "$project/.cache" -j 4
app="$project/build/Nagi.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Runtime/bin" "$app/Contents/Resources/Runtime/.build/debug"
cp "$project/bin/ASRWorker" "$app/Contents/Resources/Runtime/bin/ASRWorker.new"
mv "$app/Contents/Resources/Runtime/bin/ASRWorker.new" "$app/Contents/Resources/Runtime/bin/ASRWorker"
cp "$project/bin/LiveASRWorker" "$app/Contents/Resources/Runtime/bin/LiveASRWorker.new"
mv "$app/Contents/Resources/Runtime/bin/LiveASRWorker.new" "$app/Contents/Resources/Runtime/bin/LiveASRWorker"
cp "$project/bin/libNagiVAD.dylib" "$app/Contents/Resources/Runtime/bin/libNagiVAD.dylib.new"
mv "$app/Contents/Resources/Runtime/bin/libNagiVAD.dylib.new" "$app/Contents/Resources/Runtime/bin/libNagiVAD.dylib"
cp "$project/.build/debug/SpeakerWorker" "$app/Contents/Resources/Runtime/.build/debug/SpeakerWorker.new"
mv "$app/Contents/Resources/Runtime/.build/debug/SpeakerWorker.new" "$app/Contents/Resources/Runtime/.build/debug/SpeakerWorker"
cp "$project/THIRD_PARTY_NOTICES.md" "$project/DEPENDENCIES.json" "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/Licenses"
cp "$project/Licenses/Silero-VAD.txt" "$app/Contents/Resources/Licenses/"
cp "$project/../Dependencies/transcribe.cpp/LICENSE" "$app/Contents/Resources/Licenses/transcribe.cpp.txt"
cp "$project/../Dependencies/FluidAudio/LICENSE" "$app/Contents/Resources/Licenses/FluidAudio.txt"
cp "$project/../Dependencies/transcribe.cpp/ggml/LICENSE" "$app/Contents/Resources/Licenses/ggml.txt"
cp "$project/../Dependencies/transcribe.cpp/src/third_party/miniz/LICENSE" "$app/Contents/Resources/Licenses/miniz.txt"
cp "$project/../Dependencies/transcribe.cpp/src/third_party/silero_vad/LICENSE" "$app/Contents/Resources/Licenses/silero-vad.txt"
cp -R "$project/../Dependencies/FluidAudio/ThirdPartyLicenses" "$app/Contents/Resources/Licenses/"
if [[ -d "$project/Models" ]]; then
  mkdir -p "$app/Contents/Resources/Runtime/Models"
  rsync -a "$project/Models/" "$app/Contents/Resources/Runtime/Models/"
fi
cp "$project/.build/debug/Nagi" "$app/Contents/MacOS/Nagi.new"
mv "$app/Contents/MacOS/Nagi.new" "$app/Contents/MacOS/Nagi"
/usr/bin/python3 - "$app/Contents/Info.plist" "$project" <<'PY'
import plistlib, sys

plist = {
    "CFBundleIdentifier": "local.nagi.journal",
    "CFBundleName": "Nagi",
    "CFBundleDisplayName": "Nagi",
    "CFBundleExecutable": "Nagi",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.4.2",
    "CFBundleVersion": "9",
    "LSMinimumSystemVersion": "15.0",
    "NSMicrophoneUsageDescription": "Record a conversation or your local voice profile only when you press Start or Enroll. Audio never uploads.",
    "NSHighResolutionCapable": True,
    "NagiProject": sys.argv[2],
}
with open(sys.argv[1], "wb") as f:
    plistlib.dump(plist, f)
PY
codesign --force --sign - "$app"
print "Built $app"
