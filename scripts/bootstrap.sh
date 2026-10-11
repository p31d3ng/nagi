#!/bin/zsh
# Fetches source dependencies only. Never downloads weights implicitly.
set -euo pipefail
project=${0:A:h:h}
mkdir -p "${project:h}/Dependencies"
fetch() {
  name=$1
  remote=$2
  revision=$3
  dest="${project:h}/Dependencies/$name"
  if [[ -d "$dest" ]]; then
    [[ $(git -C "$dest" rev-parse HEAD) == "$revision" ]] || {
      print -u2 "Existing $dest has another revision; preserve it and resolve manually."
      exit 1
    }
  else
    git clone "$remote" "$dest"
    git -C "$dest" checkout --detach "$revision"
  fi
}
fetch transcribe.cpp \
  https://github.com/handy-computer/transcribe.cpp.git \
  5d66f60257a75e9bdbddc72dc0887b32e9d4841a
fetch FluidAudio \
  https://github.com/FluidInference/FluidAudio.git \
  fc8c3e4f5103bf63a242453566525272e143a054
