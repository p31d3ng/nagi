#!/bin/zsh
# Explicit opt-in setup; model weights have separate terms. No uploads.
set -euo pipefail
project=${0:A:h:h}
print 'Read THIRD_PARTY_NOTICES.md and the linked model cards before downloading.'
mkdir -p "$project/Models" "$project/reports"
fetch() {
  repo=$1; revision=$2; file=$3; checksum=$4; dest="$project/Models/$file"
  if [[ ! -f "$dest" ]]; then
    curl -L --fail --retry 2 "https://huggingface.co/$repo/resolve/$revision/$file" -o "$dest.partial"
    print "$checksum  $dest.partial" | shasum -a 256 -c -
    mv "$dest.partial" "$dest"
  fi
  print "$checksum  $dest" | shasum -a 256 -c -
}
fetch handy-computer/parakeet-unified-en-0.6b-gguf 7e948f21b7bdbac698d3318db9d350f1096f3b6c parakeet-unified-en-0.6b-Q8_0.gguf 4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795
fetch handy-computer/whisper-medium-gguf ec78f06fded51aa82cde751678b78f76f78c8b7f whisper-medium-Q4_K_M.gguf 6c9cad9c41d1fa0fcc624898f7ee3485b66127627878081a5655c6f6f3ce20ab
[[ -f "$project/Fixtures/english.wav" ]] || python3 "$project/scripts/fixtures.py"
"$project/.build/debug/SpeakerWorker" "$project/Fixtures/english.wav" "$project/reports/setup-speakers.json" "$project/Models/Community1" --prepare
