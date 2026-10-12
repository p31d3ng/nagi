// Nagi adapter to the pinned transcribe.cpp public C API.
#include "transcribe.h"
#include "wav.h"
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
static std::string json(const char *s) {
    std::string out = "\"";
    for (const unsigned char c : std::string(s ? s : "")) {
        if (c == '"')
            out += "\\\"";
        else if (c == '\\')
            out += "\\\\";
        else if (c == '\n')
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
    if (argc != 4) {
        std::cerr << "ASRWorker model wav output\n";
        return 1;
    }
    std::vector<float> pcm;
    std::string error;
    if (!transcribe_cli::load_wav_mono_16k(argv[2], pcm, error)) {
        std::cerr << error;
        return 2;
    }
    if (pcm.size() > 16'000 * 12) {
        std::cerr << "Input exceeds bounded 12 second job";
        return 2;
    }
    std::cerr << "NAGI_STAGE model_loading\n";
    transcribe_model_load_params load;
    transcribe_model_load_params_init(&load);
    load.backend = TRANSCRIBE_BACKEND_METAL;
    transcribe_model *model = nullptr;
    auto status = transcribe_model_load_file(argv[1], &load, &model);
    if (status != TRANSCRIBE_OK) {
        std::cerr << transcribe_status_string(status);
        return 3;
    }
    transcribe_session_params sp;
    transcribe_session_params_init(&sp);
    sp.n_threads = 2;
    transcribe_session *session = nullptr;
    status = transcribe_session_init(model, &sp, &session);
    if (status != TRANSCRIBE_OK) {
        std::cerr << transcribe_status_string(status);
        transcribe_model_free(model);
        return 3;
    }
    std::cerr << "NAGI_STAGE transcribing\n";
    std::string streaming;
    if (std::string(argv[1]).find("parakeet-unified-en") != std::string::npos) {
        status = transcribe_stream_begin(session, nullptr, nullptr);
        for (size_t pos = 0; status == TRANSCRIBE_OK && pos < pcm.size(); pos += 5120) {
            transcribe_stream_update update;
            transcribe_stream_update_init(&update);
            status = transcribe_stream_feed(session, pcm.data() + pos,
                                            int(std::min(size_t(5120), pcm.size() - pos)), &update);
        }
        if (status == TRANSCRIBE_OK) {
            transcribe_stream_update update;
            transcribe_stream_update_init(&update);
            status = transcribe_stream_finalize(session, &update);
        }
        if (status != TRANSCRIBE_OK) {
            std::cerr << transcribe_status_string(status);
            transcribe_session_free(session);
            transcribe_model_free(model);
            return 4;
        }
        streaming = transcribe_full_text(session);
    }
    // Current engine streaming path omits word timing. A sequential offline pass
    // supplies aligned word rows. Both uncorrected outputs are kept by the store.
    if (!streaming.empty()) std::cerr << "NAGI_STAGE aligning\n";
    transcribe_run_params rp;
    transcribe_run_params_init(&rp);
    status = transcribe_run(session, pcm.data(), int(pcm.size()), &rp);
    if (status != TRANSCRIBE_OK) {
        std::cerr << transcribe_status_string(status);
        transcribe_session_free(session);
        transcribe_model_free(model);
        return 4;
    }
    std::ofstream out(argv[3]);
    out << "{\"streaming_text\":" << json(streaming.c_str())
        << ",\"text\":" << json(transcribe_full_text(session))
        << ",\"language\":" << json(transcribe_detected_language(session)) << ",\"segments\":[";
    int words = transcribe_n_words(session), segments = transcribe_n_segments(session);
    bool first = true;
    if (words > 0) {
        for (int i = 0; i < words; i++) {
            transcribe_word word;
            transcribe_word_init(&word);
            transcribe_get_word(session, i, &word);
            if (!first)
                out << ",";
            first = false;
            out << "{\"t0_ms\":" << word.t0_ms << ",\"t1_ms\":" << word.t1_ms
                << ",\"text\":" << json(word.text) << "}";
        }
    } else {
        for (int i = 0; i < segments; i++) {
            transcribe_segment seg;
            transcribe_segment_init(&seg);
            transcribe_get_segment(session, i, &seg);
            if (!first)
                out << ",";
            first = false;
            out << "{\"t0_ms\":" << seg.t0_ms << ",\"t1_ms\":" << seg.t1_ms
                << ",\"text\":" << json(seg.text) << "}";
        }
    }
    out << "]}";
    out.close();
    transcribe_session_free(session);
    transcribe_model_free(model);
    return 0;
}
