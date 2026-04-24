// Stub implementations for download and hf-cache functions
// These are not needed on HarmonyOS as models are pre-loaded on device

#include "download.h"
#include "arg.h"
#include <utility>

// Stub implementations to satisfy linker

namespace hf_cache {
    void migrate_old_cache_to_hf_cache(const std::string&, bool) {
        // Not implemented - models pre-loaded on device
    }
}

std::pair<std::string, std::string> common_download_split_repo_tag(const std::string&) {
    return {"", ""};
}

int common_download_file_single(const std::string&, const std::string&, const common_download_opts&, bool) {
    return -1; // error
}

std::string common_docker_resolve_model(const std::string&) {
    return "";
}

common_download_model_result common_download_model(const common_params_model&, const common_download_opts&, bool) {
    return {}; // empty result
}

std::vector<common_cached_model_info> common_list_cached_models() {
    return {};
}

// License info stub - referenced from arg.cpp
extern const char * LICENSES = "";