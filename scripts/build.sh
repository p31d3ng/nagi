#!/bin/zsh
set -euo pipefail
project=${0:A:h:h}
export CLANG_MODULE_CACHE_PATH="$project/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$project/.cache/swift"
"$project/scripts/build-native.sh"
swift build --disable-sandbox --package-path "$project" --scratch-path "$project/.build" --cache-path "$project/.cache" -j 4
app="$project/build/Nagi.app"
mkdir -p "$app/Contents/MacOS"
cp "$project/.build/debug/Nagi" "$app/Contents/MacOS/Nagi"
/usr/bin/python3 - "$app/Contents/Info.plist" "$project" <<'PY'
import plistlib,sys
plist={'CFBundleIdentifier':'local.nagi.journal','CFBundleName':'Nagi','CFBundleDisplayName':'Nagi','CFBundleExecutable':'Nagi','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1','LSMinimumSystemVersion':'15.0','NSMicrophoneUsageDescription':'Record a conversation or your local voice profile only when you press Start or Enroll. Audio never uploads.','NSHighResolutionCapable':True,'NagiProject':sys.argv[2]}
with open(sys.argv[1],'wb') as f:plistlib.dump(plist,f)
PY
codesign --force --sign - "$app"
print "Built $app"
