#include "transcribe.h"
#include "transcribe/vad.h"
#include <cmath>

struct Gate {
    transcribe_model *model;
    transcribe_vad_session *session;
};
extern "C" void *nagi_vad_create(const char *path) {
    // Avoid initializing Metal at all for this tiny CPU-only detector.
    transcribe_backend_init_params backends;
    transcribe_backend_init_params_init(&backends);
    backends.allowed_backends = TRANSCRIBE_BACKEND_MASK_CPU;
    if (transcribe_init_backends_ex(&backends) != TRANSCRIBE_OK)
        return nullptr;
    auto *g = new Gate{nullptr, nullptr};
    transcribe_model_load_params load;
    transcribe_model_load_params_init(&load);
    load.backend = TRANSCRIBE_BACKEND_CPU;
    transcribe_vad_session_params params;
    transcribe_vad_session_params_init(&params);
    params.n_threads = 1;
    if (transcribe_model_load_file(path, &load, &g->model) != TRANSCRIBE_OK ||
        transcribe_vad_session_init(g->model, &params, &g->session) != TRANSCRIBE_OK) {
        transcribe_model_free(g->model);
        delete g;
        return nullptr;
    }
    return g;
}
extern "C" float nagi_vad_score(void *handle, const float *pcm) {
    auto *g = static_cast<Gate *>(handle);
    if (!g || transcribe_vad_stream_feed(g->session, pcm, 512) != TRANSCRIBE_OK)
        return -1;
    transcribe_vad_result r;
    transcribe_vad_result_init(&r);
    if (transcribe_vad_get_result(g->session, &r) != TRANSCRIBE_OK || r.n_probs != 1)
        return -1;
    float p = transcribe_vad_probs(g->session)[0];
    return std::isfinite(p) ? p : -1;
}
extern "C" void nagi_vad_free(void *handle) {
    auto *g = static_cast<Gate *>(handle);
    if (!g)
        return;
    transcribe_vad_session_free(g->session);
    transcribe_model_free(g->model);
    delete g;
}
extern "C" void nagi_vad_reset(void *handle) {
    auto *g = static_cast<Gate *>(handle);
    if (g) transcribe_vad_stream_reset(g->session);
}
