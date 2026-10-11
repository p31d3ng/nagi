#!/bin/zsh
set -euo pipefail
project=${0:A:h:h}
dep=${project:h}/Dependencies/transcribe.cpp
cmake -S "$dep" -B "$dep/build" -DCMAKE_BUILD_TYPE=Release -DTRANSCRIBE_BUILD_TESTS=OFF
cmake --build "$dep/build" -j 4
mkdir -p "$project/bin"
c++ -O3 -std=c++17 \
  -I "$dep/include" \
  -I "$dep/examples/common" \
  "$project/Native/ASRWorker.cpp" \
  "$dep/build/src/libtranscribe.a" \
  "$dep/build/examples/common/libtranscribe-common-example.a" \
  "$dep/build/ggml/src/libggml.a" \
  "$dep/build/ggml/src/libggml-cpu.a" \
  "$dep/build/ggml/src/ggml-metal/libggml-metal.a" \
  "$dep/build/ggml/src/libggml-base.a" \
  -framework Accelerate \
  -framework Foundation \
  -framework Metal \
  -framework MetalKit \
  -o "$project/bin/ASRWorker"

c++ -O3 -std=c++17 \
  -I "$dep/include" \
  -I "$dep/examples/common" \
  "$project/Native/LiveASRWorker.cpp" \
  "$dep/build/src/libtranscribe.a" \
  "$dep/build/examples/common/libtranscribe-common-example.a" \
  "$dep/build/ggml/src/libggml.a" \
  "$dep/build/ggml/src/libggml-cpu.a" \
  "$dep/build/ggml/src/ggml-metal/libggml-metal.a" \
  "$dep/build/ggml/src/libggml-base.a" \
  -framework Accelerate \
  -framework Foundation \
  -framework Metal \
  -framework MetalKit \
  -o "$project/bin/LiveASRWorker"
