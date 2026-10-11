// Persistent, bounded English preview stream. Archival audio remains authoritative.
#include "transcribe.h"
#include "transcribe/parakeet.h"
#include <algorithm>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

static std::string quote(const char *s) {
    std::string out = "\"";
    for (unsigned char c : std::string(s ? s : "")) {
        if (c == '"' || c == '\\') {
            out += '\\';
            out += c;
        } else if (c == '\n')
            out += "\\n";
        else if (c == '\r')
            out += "\\r";
        else if (c == '\t')
            out += "\\t";
        else if (c >= 32)
            out += c;
    }
    return out + "\"";
}
int main(int argc, char **argv) {
    if (argc < 2 || argc > 3)
        return 1;
    transcribe_model_load_params load;
    transcribe_model_load_params_init(&load);
    load.backend = TRANSCRIBE_BACKEND_METAL;
    transcribe_model *model = nullptr;
    auto status = transcribe_model_load_file(argv[1], &load, &model);
    if (status != TRANSCRIBE_OK)
        return 2;
    transcribe_session_params params;
    transcribe_session_params_init(&params);
    params.n_threads = 2;
    transcribe_session *session = nullptr;
    status = transcribe_session_init(model, &params, &session);
    if (status != TRANSCRIBE_OK) {
        transcribe_model_free(model);
        return 3;
    }
    auto check = [&](transcribe_status s) {
        if (s != TRANSCRIBE_OK)
            std::cerr << transcribe_status_string(s) << '\n';
        return s == TRANSCRIBE_OK;
    };
    transcribe_parakeet_buffered_stream_ext geometry;
    transcribe_parakeet_buffered_stream_ext_init(&geometry);
    if (argc == 3 && std::string(argv[2]) == "balanced") {
        geometry.left_ms = 5600;
        geometry.chunk_ms = 560;
        geometry.right_ms = 560;
    }
    transcribe_stream_params stream;
    transcribe_stream_params_init(&stream);
    stream.family = &geometry.ext;
    bool active = false;
    int frames = 0;
    double offset = 0;
    auto emit = [&](bool final) {
        transcribe_stream_text text;
        transcribe_stream_text_init(&text);
        if (!check(transcribe_stream_get_text(session, &text)))
            return;
        std::cout << "{\"offset\":" << offset << ",\"duration\":" << frames / 16000.0
                  << ",\"full\":" << quote(text.full_text)
                  << ",\"committed\":" << quote(text.committed_text)
                  << ",\"tentative\":" << quote(text.tentative_text)
                  << ",\"final\":" << (final ? "true" : "false") << "}\n"
                  << std::flush;
    };
    std::cout << "{\"ready\":true}\n" << std::flush;
    // Wire packets: native little-endian UInt32 frame count, Double source offset, Float32 mono
    // 16k. Both sides run on this Apple Silicon Mac; reject unreasonable packets before allocating.
    uint32_t count;
    while (std::cin.read(reinterpret_cast<char *>(&count), sizeof(count))) {
        if (count == 0)
            break;
        if (count == UINT32_MAX) {
            if (active) {
                if (!check(transcribe_stream_finalize(session, nullptr)))
                    return 7;
                emit(true);
                active = false;
            }
            continue;
        }
        double sourceOffset;
        if (count > 16384 ||
            !std::cin.read(reinterpret_cast<char *>(&sourceOffset), sizeof(sourceOffset)))
            return 4;
        std::vector<float> pcm(count);
        if (!std::cin.read(reinterpret_cast<char *>(pcm.data()), count * sizeof(float)))
            return 4;
        // A speech-only archive preserves elapsed offsets. Never concatenate omitted time.
        if (active && sourceOffset > offset + frames / 16000.0 + 0.01) {
            if (!check(transcribe_stream_finalize(session, nullptr)))
                return 7;
            emit(true);
            active = false;
        }
        for (uint32_t pos = 0; pos < count;) {
            if (!active) {
                if (!check(transcribe_stream_begin(session, nullptr, &stream)))
                    return 5;
                active = true;
                frames = 0;
                offset = sourceOffset + pos / 16000.0;
            }
            int n = std::min({int(count - pos), 5120, 480000 - frames});
            transcribe_stream_update update;
            transcribe_stream_update_init(&update);
            if (!check(transcribe_stream_feed(session, pcm.data() + pos, n, &update)))
                return 6;
            frames += n;
            pos += n;
            if (update.result_changed)
                emit(false);
            if (frames == 480000) {
                if (!check(transcribe_stream_finalize(session, nullptr)))
                    return 7;
                emit(true);
                active = false;
            }
        }
    }
    if (active) {
        if (!check(transcribe_stream_finalize(session, nullptr)))
            return 7;
        emit(true);
    }
    transcribe_session_free(session);
    transcribe_model_free(model);
    return 0;
}
