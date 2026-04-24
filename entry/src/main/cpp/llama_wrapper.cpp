#include "llama_wrapper.h"
#include "mtmd-helper.h"
#include <chrono>
#include <cstring>
#include <cerrno>
#include <cstdio>
#include <hilog/log.h>
#include <cstdarg>
#include <ctime>

// HarmonyOS 日志宏
#define LOG_TAG "LlamaWrapper"
#define LOG_DOMAIN 0x03D00

// 全局 wrapper 指针用于日志回调
static LlamaWrapper* g_wrapper_for_log = nullptr;

// llama.cpp 日志回调 - 同时写入 hilog 和文件 (非 static，与头文件声明匹配)
void llama_log_callback(ggml_log_level level, const char * text, void * user_data) {
    (void) user_data;

    // 移除末尾换行符
    std::string msg(text);
    if (!msg.empty() && msg.back() == '\n') {
        msg.pop_back();
    }

    // 写入 hilog
    switch (level) {
        case GGML_LOG_LEVEL_ERROR:
            OH_LOG_ERROR(LOG_APP, "llama: %{public}s", msg.c_str());
            break;
        case GGML_LOG_LEVEL_WARN:
            OH_LOG_WARN(LOG_APP, "llama: %{public}s", msg.c_str());
            break;
        case GGML_LOG_LEVEL_INFO:
            OH_LOG_INFO(LOG_APP, "llama: %{public}s", msg.c_str());
            break;
        default:
            OH_LOG_INFO(LOG_APP, "llama: %{public}s", msg.c_str());
            break;
    }

    // 同时写入文件日志
    if (g_wrapper_for_log && g_wrapper_for_log->logFile_) {
        const char* levelStr = "INFO";
        switch (level) {
            case GGML_LOG_LEVEL_ERROR: levelStr = "ERROR"; break;
            case GGML_LOG_LEVEL_WARN:  levelStr = "WARN";  break;
            case GGML_LOG_LEVEL_DEBUG: levelStr = "DEBUG"; break;
            default: levelStr = "INFO"; break;
        }

        time_t now = time(nullptr);
        struct tm* tm_info = localtime(&now);
        char timeBuf[32];
        strftime(timeBuf, sizeof(timeBuf), "%H:%M:%S", tm_info);

        fprintf(g_wrapper_for_log->logFile_, "[%s] [%s] %s\n", timeBuf, levelStr, msg.c_str());
        fflush(g_wrapper_for_log->logFile_);
    }
}

LlamaWrapper::LlamaWrapper()
    : loaded_(false)
    , modelPath_()
    , mmprojPath_()
    , tokenCount_(0)
    , tokensPerSecond_(0.0f)
    , model_(nullptr)
    , ctx_(nullptr)
    , mtmdCtx_(nullptr)
    , logFilePath_()
    , logFile_(nullptr)
{
    g_wrapper_for_log = this;
    OH_LOG_INFO(LOG_APP, "LlamaWrapper: Initialized");
}

LlamaWrapper::~LlamaWrapper() {
    if (logFile_) {
        fclose(logFile_);
        logFile_ = nullptr;
    }
    g_wrapper_for_log = nullptr;
    unload();
}

void LlamaWrapper::setLogFile(const std::string& logPath) {
    if (logFile_) {
        fclose(logFile_);
        logFile_ = nullptr;
    }

    logFilePath_ = logPath;
    logFile_ = fopen(logPath.c_str(), "a");

    if (logFile_) {
        OH_LOG_INFO(LOG_APP, "LlamaWrapper: Log file set to %{public}s", logPath.c_str());
        writeLog("INFO", "=== LlamaWrapper log file initialized ===");
        writeLog("INFO", "Log path: %s", logPath.c_str());

        // 设置 llama.cpp 日志回调
        llama_log_set(llama_log_callback, nullptr);
        writeLog("INFO", "llama.cpp log callback installed");
    } else {
        OH_LOG_ERROR(LOG_APP, "LlamaWrapper: Failed to open log file %{public}s (errno=%{public}d)",
                     logPath.c_str(), errno);
    }
}

void LlamaWrapper::writeLog(const char* level, const char* format, ...) {
    if (!logFile_) return;

    time_t now = time(nullptr);
    struct tm* tm_info = localtime(&now);
    char timeBuf[32];
    strftime(timeBuf, sizeof(timeBuf), "%H:%M:%S", tm_info);

    fprintf(logFile_, "[%s] [%s] ", timeBuf, level);

    va_list args;
    va_start(args, format);
    vfprintf(logFile_, format, args);
    va_end(args);

    fprintf(logFile_, "\n");
    fflush(logFile_);
}

bool LlamaWrapper::loadModel(const std::string& modelPath, const std::string& mmprojPath) {
    if (loaded_) {
        unload();
    }

    modelPath_ = modelPath;
    mmprojPath_ = mmprojPath;

    OH_LOG_INFO(LOG_APP, "LlamaWrapper: Loading model from %{public}s", modelPath.c_str());
    writeLog("INFO", "loadModel: path=%s", modelPath.c_str());

    // 检查文件是否存在和可访问
    FILE* f = fopen(modelPath.c_str(), "rb");
    if (!f) {
        OH_LOG_ERROR(LOG_APP, "LlamaWrapper: Cannot open file %{public}s (errno=%{public}d)", modelPath.c_str(), errno);
        writeLog("ERROR", "Cannot open file %s (errno=%d)", modelPath.c_str(), errno);
        return false;
    }

    // 获取文件大小
    fseek(f, 0, SEEK_END);
    long fileSize = ftell(f);
    fseek(f, 0, SEEK_SET);
    writeLog("INFO", "File opened, size=%ld bytes", fileSize);

    // 读取文件头验证 GGUF 格式
    char magic[4] = {0};
    size_t read = fread(magic, 1, 4, f);
    fclose(f);

    if (read != 4) {
        OH_LOG_ERROR(LOG_APP, "LlamaWrapper: Cannot read file header (read=%{public}zu)", read);
        writeLog("ERROR", "Cannot read file header (read=%zu)", read);
        return false;
    }

    OH_LOG_INFO(LOG_APP, "LlamaWrapper: File magic: %{public}02x%{public}02x%{public}02x%{public}02x",
                magic[0], magic[1], magic[2], magic[3]);
    writeLog("INFO", "File magic: %02x%02x%02x%02x (%c%c%c%c)",
             magic[0], magic[1], magic[2], magic[3],
             magic[0], magic[1], magic[2], magic[3]);

    if (magic[0] != 'G' || magic[1] != 'G' || magic[2] != 'U' || magic[3] != 'F') {
        OH_LOG_ERROR(LOG_APP, "LlamaWrapper: Invalid GGUF magic");
        writeLog("ERROR", "Invalid GGUF magic - expected GGUF");
        return false;
    }

    OH_LOG_INFO(LOG_APP, "LlamaWrapper: GGUF magic valid, proceeding to load");
    writeLog("INFO", "GGUF magic valid, initializing backend");

    // 初始化 llama.cpp 后端
    llama_backend_init();
    OH_LOG_INFO(LOG_APP, "LlamaWrapper: Backend initialized");
    writeLog("INFO", "llama_backend_init() completed");

    // 模型参数
    llama_model_params model_params = llama_model_default_params();
    OH_LOG_INFO(LOG_APP, "LlamaWrapper: Using default model params");
    writeLog("INFO", "Using default model params (n_gpu_layers=%d, use_mmap=%d)",
             model_params.n_gpu_layers, model_params.use_mmap);

    // 加载模型
    OH_LOG_INFO(LOG_APP, "LlamaWrapper: Calling llama_load_model_from_file...");
    writeLog("INFO", "Calling llama_load_model_from_file...");

    model_ = llama_load_model_from_file(modelPath.c_str(), model_params);
    if (!model_) {
        OH_LOG_ERROR(LOG_APP, "LlamaWrapper: llama_load_model_from_file returned NULL for %{public}s", modelPath.c_str());
        writeLog("ERROR", "llama_load_model_from_file returned NULL - model loading failed");
        return false;
    }
    OH_LOG_INFO(LOG_APP, "LlamaWrapper: Model loaded successfully");
    writeLog("INFO", "Model loaded successfully, model=%p", model_);

    // 上下文参数 - 推荐配置
    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = 2048;        // 恢复 2048（eval_chunks 需要足够空间）
    ctx_params.n_batch = 256;       // 恢复 256
    ctx_params.n_ubatch = 256;      // 恢复 256
    ctx_params.n_threads = 8;       // 增加线程数（利用更多大核）
    ctx_params.n_threads_batch = 8;
    writeLog("INFO", "Context params: n_ctx=%d, n_batch=%d, n_threads=%d",
             ctx_params.n_ctx, ctx_params.n_batch, ctx_params.n_threads);

    // 创建上下文
    ctx_ = llama_new_context_with_model(model_, ctx_params);
    if (!ctx_) {
        OH_LOG_ERROR(LOG_APP, "LlamaWrapper: Failed to create context");
        writeLog("ERROR", "Failed to create context");
        llama_free_model(model_);
        model_ = nullptr;
        return false;
    }

    loaded_ = true;
    OH_LOG_INFO(LOG_APP, "LlamaWrapper: Model loaded successfully");
    writeLog("INFO", "=== Model loading complete ===");

    // 如果有 mmproj 文件，初始化多模态上下文
    if (!mmprojPath.empty()) {
        writeLog("INFO", "Initializing mtmd context with mmproj: %s", mmprojPath.c_str());

        mtmd_context_params mtmd_params = mtmd_context_params_default();
        mtmd_params.use_gpu = false;  // HarmonyOS 使用 CPU
        mtmd_params.n_threads = 4;
        mtmd_params.print_timings = true;

        mtmdCtx_ = mtmd_init_from_file(mmprojPath.c_str(), model_, mtmd_params);
        if (mtmdCtx_) {
            writeLog("INFO", "mtmd context initialized successfully");
            OH_LOG_INFO(LOG_APP, "LlamaWrapper: Multimodal support enabled");
        } else {
            writeLog("WARN", "Failed to initialize mtmd context - vision disabled");
            OH_LOG_WARN(LOG_APP, "LlamaWrapper: Failed to load mmproj, vision disabled");
        }
    }

    return true;
}

bool LlamaWrapper::isLoaded() const {
    return loaded_;
}

bool LlamaWrapper::supportsVision() const {
    return mtmdCtx_ != nullptr && mtmd_support_vision(mtmdCtx_);
}

std::string LlamaWrapper::generate(const std::string& prompt, int maxTokens) {
    if (!loaded_ || !ctx_ || !model_) {
        OH_LOG_ERROR(LOG_APP, "LlamaWrapper: Model not loaded");
        return "";
    }

    OH_LOG_INFO(LOG_APP, "LlamaWrapper: Generating for prompt length=%{public}zu", prompt.length());
    writeLog("INFO", "generate: prompt length=%zu", prompt.length());

    auto startTime = std::chrono::high_resolution_clock::now();

    // 清除内存 (KV cache 和 recurrent memory) - 必须在每次新生成前清除
    llama_memory_t mem = llama_get_memory(ctx_);
    llama_memory_clear(mem, true);
    OH_LOG_INFO(LOG_APP, "LlamaWrapper: Memory cleared");
    writeLog("INFO", "Memory cleared before generation");

    // 获取 vocab
    const llama_vocab* vocab = llama_model_get_vocab(model_);
    writeLog("INFO", "vocab obtained");

    // 编码 prompt - 需要预分配空间
    std::vector<llama_token> tokens;
    tokens.resize(prompt.length() + 1);  // 预分配足够空间
    writeLog("INFO", "tokenize: calling llama_tokenize with prompt len=%zu", prompt.length());

    int n_tokens = llama_tokenize(
        vocab,
        prompt.c_str(),
        static_cast<int32_t>(prompt.length()),
        tokens.data(),
        static_cast<int32_t>(tokens.size()),
        true,   // add_bos
        false   // special tokens
    );
    writeLog("INFO", "tokenize: returned n_tokens=%d", n_tokens);

    if (n_tokens < 0) {
        OH_LOG_ERROR(LOG_APP, "LlamaWrapper: Failed to encode prompt (n_tokens=%{public}d)", n_tokens);
        writeLog("ERROR", "Failed to encode prompt (n_tokens=%d)", n_tokens);
        return "";
    }

    tokens.resize(n_tokens);
    OH_LOG_INFO(LOG_APP, "LlamaWrapper: Prompt encoded to %{public}d tokens", n_tokens);
    writeLog("INFO", "Prompt encoded to %d tokens", n_tokens);

    // 创建 batch 并填充 prompt tokens
    llama_batch batch = llama_batch_init(n_tokens + maxTokens, 0, 1);
    writeLog("INFO", "batch initialized (size=%d)", n_tokens + maxTokens);

    for (int i = 0; i < n_tokens; i++) {
        batch.token[i] = tokens[i];
        batch.pos[i] = i;
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i] = 0;  // 不需要中间 token 的 logits
    }
    batch.n_tokens = n_tokens;

    // 设置最后一个 token 的 logits
    batch.logits[n_tokens - 1] = 1;

    // 解码 prompt
    writeLog("INFO", "calling llama_decode for prompt batch");
    int ret = llama_decode(ctx_, batch);
    writeLog("INFO", "llama_decode returned %d", ret);

    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "LlamaWrapper: Failed to decode prompt batch (ret=%{public}d)", ret);
        writeLog("ERROR", "Failed to decode prompt batch (ret=%d)", ret);
        llama_batch_free(batch);
        return "";
    }
    writeLog("INFO", "Prompt batch decoded successfully");

    // 生成 tokens
    std::vector<llama_token> generated_tokens;
    generated_tokens.reserve(maxTokens);

    // 创建采样器链 - 推荐参数
    llama_sampler* sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.6f));
    llama_sampler_chain_add(sampler, llama_sampler_init_penalties(64, 1.1f, 0.0f, 0.0f));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(12345));

    int n_past = n_tokens;

    for (int i = 0; i < maxTokens; i++) {
        // 采样下一个 token
        llama_token new_token = llama_sampler_sample(sampler, ctx_, batch.n_tokens - 1);

        // 检查是否是 EOS
        if (llama_vocab_is_eog(vocab, new_token)) {
            OH_LOG_INFO(LOG_APP, "LlamaWrapper: EOS token detected at %{public}d", i);
            break;
        }

        generated_tokens.push_back(new_token);

        // 添加新 token 到 batch
        batch.token[0] = new_token;
        batch.pos[0] = n_past;
        batch.n_seq_id[0] = 1;
        batch.seq_id[0][0] = 0;
        batch.logits[0] = 1;  // 需要这个 token 的 logits 用于下一次采样
        batch.n_tokens = 1;

        // 解码
        ret = llama_decode(ctx_, batch);
        if (ret != 0) {
            OH_LOG_ERROR(LOG_APP, "LlamaWrapper: Failed to decode token %{public}d (ret=%{public}d)", i, ret);
            break;
        }

        n_past++;
    }

    // 将 tokens 转换为文本
    std::string result;

    for (llama_token token : generated_tokens) {
        char buf[16];
        int len = llama_token_to_piece(vocab, token, buf, sizeof(buf), 0, false);
        if (len > 0) {
            result.append(buf, len);
        }
    }

    auto endTime = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(endTime - startTime);

    tokenCount_ = static_cast<int>(generated_tokens.size());
    tokensPerSecond_ = duration.count() > 0 ?
        static_cast<float>(tokenCount_) * 1000.0f / static_cast<float>(duration.count()) : 0.0f;

    OH_LOG_INFO(LOG_APP, "LlamaWrapper: Generated %{public}d tokens in %{public}lldms (%{public}.2f t/s)",
                tokenCount_, (long long)duration.count(), tokensPerSecond_);

    llama_sampler_free(sampler);
    llama_batch_free(batch);

    return result;
}

std::string LlamaWrapper::generateCaption(
    const uint8_t* imageData,
    int width,
    int height,
    int maxTokens
) {
    if (!loaded_ || !ctx_) {
        OH_LOG_ERROR(LOG_APP, "LlamaWrapper: Model not loaded");
        return "";
    }

    writeLog("INFO", "generateCaption: %dx%d image, maxTokens=%d", width, height, maxTokens);
    auto startTime = std::chrono::high_resolution_clock::now();

    // 清除内存
    llama_memory_t mem = llama_get_memory(ctx_);
    llama_memory_clear(mem, true);
    writeLog("INFO", "Memory cleared");

    // 如果有 mtmd 上下文，使用多模态处理
    if (mtmdCtx_ && mtmd_support_vision(mtmdCtx_)) {
        writeLog("INFO", "Using mtmd for vision processing");

        // 图像预调整大小以加速编码 (减小分辨率提速)
        const int MAX_SIZE = 512;
        int newWidth = width;
        int newHeight = height;

        if (width > MAX_SIZE || height > MAX_SIZE) {
            float scale = std::min((float)MAX_SIZE / width, (float)MAX_SIZE / height);
            newWidth = (int)(width * scale);
            newHeight = (int)(height * scale);
            writeLog("INFO", "Resizing image from %dx%d to %dx%d", width, height, newWidth, newHeight);
        }

        // 创建调整大小后的 RGB 数据
        std::vector<unsigned char> rgbData(newWidth * newHeight * 3);

        if (newWidth != width || newHeight != height) {
            // 简单的最近邻缩放 (从 RGBA)
            for (int y = 0; y < newHeight; y++) {
                for (int x = 0; x < newWidth; x++) {
                    int srcX = (int)(x * (float)width / newWidth);
                    int srcY = (int)(y * (float)height / newHeight);
                    int srcIdx = (srcY * width + srcX) * 4;
                    int dstIdx = (y * newWidth + x) * 3;
                    rgbData[dstIdx + 0] = imageData[srcIdx + 0];  // R
                    rgbData[dstIdx + 1] = imageData[srcIdx + 1];  // G
                    rgbData[dstIdx + 2] = imageData[srcIdx + 2];  // B
                }
            }
        } else {
            // 原始大小，仅转换 RGBA 到 RGB
            for (int i = 0; i < width * height; i++) {
                rgbData[i * 3 + 0] = imageData[i * 4 + 0];  // R
                rgbData[i * 3 + 1] = imageData[i * 4 + 1];  // G
                rgbData[i * 3 + 2] = imageData[i * 4 + 2];  // B
            }
        }
        writeLog("INFO", "RGB data prepared, size=%zu", rgbData.size());

        // 创建 bitmap (RGB 格式)
        mtmd_bitmap* bitmap = mtmd_bitmap_init(newWidth, newHeight, rgbData.data());
        if (!bitmap) {
            writeLog("ERROR", "Failed to create mtmd_bitmap");
            OH_LOG_ERROR(LOG_APP, "LlamaWrapper: Failed to create image bitmap");
            return "";
        }
        writeLog("INFO", "mtmd_bitmap created: %dx%d", mtmd_bitmap_get_nx(bitmap), mtmd_bitmap_get_ny(bitmap));

        // 准备文本 prompt (包含图像标记)
        std::string prompt = std::string(mtmd_default_marker()) + "\n请详细描述这张图片的内容。";
        writeLog("INFO", "Prompt with marker: %s", prompt.c_str());

        // Tokenize 文本 + 图像
        mtmd_input_text text;
        text.text = prompt.c_str();
        text.add_special = true;
        text.parse_special = true;

        mtmd_input_chunks* chunks = mtmd_input_chunks_init();
        const mtmd_bitmap* bitmaps[1] = { bitmap };

        int32_t tokenize_result = mtmd_tokenize(mtmdCtx_, chunks, &text, bitmaps, 1);
        writeLog("INFO", "mtmd_tokenize returned %d", tokenize_result);

        if (tokenize_result != 0) {
            writeLog("ERROR", "mtmd_tokenize failed");
            mtmd_bitmap_free(bitmap);
            mtmd_input_chunks_free(chunks);
            return "";
        }

        writeLog("INFO", "Chunks size: %zu, total tokens: %zu, total pos: %d",
                 mtmd_input_chunks_size(chunks),
                 mtmd_helper_get_n_tokens(chunks),
                 mtmd_helper_get_n_pos(chunks));

        // 使用 mtmd_helper_eval_chunks 处理所有 chunks (包括文本和图像)
        // 设置 logits_last=true 以确保最后一帧有 logits 可用于采样
        llama_pos n_past = 0;
        llama_pos new_n_past = 0;

        int32_t eval_result = mtmd_helper_eval_chunks(
            mtmdCtx_, ctx_, chunks,
            n_past,           // n_past
            0,                // seq_id
            256,              // n_batch (与 ctx_params.n_batch 一致)
            true,             // logits_last - 重要! 确保最后一帧有 logits
            &new_n_past);

        writeLog("INFO", "mtmd_helper_eval_chunks returned %d, new_n_past=%d", eval_result, new_n_past);

        if (eval_result != 0) {
            writeLog("ERROR", "mtmd_helper_eval_chunks failed: %d", eval_result);
            mtmd_bitmap_free(bitmap);
            mtmd_input_chunks_free(chunks);
            return "";
        }

        n_past = new_n_past;
        writeLog("INFO", "All chunks processed, n_past=%d, logits should be available", n_past);

        // 清理
        mtmd_bitmap_free(bitmap);
        mtmd_input_chunks_free(chunks);

        // 生成回复 - 使用推荐的采样参数
        writeLog("INFO", "Starting token generation with recommended sampling params...");
        const llama_vocab* vocab = llama_model_get_vocab(model_);

        // 创建采样器链: top_k -> top_p -> temp -> dist (移除 penalties 减少开销)
        llama_sampler* sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40));
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9f, 1));
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.6f));
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(12345));

        std::vector<llama_token> generated_tokens;
        generated_tokens.reserve(maxTokens);

        llama_batch gen_batch = llama_batch_init(1, 0, 1);

        // 尝试获取 logits - 检查 embedding 处理后是否有有效 logits
        float* logits = llama_get_logits(ctx_);
        writeLog("INFO", "llama_get_logits returned: %p", logits);

        if (logits == nullptr) {
            writeLog("ERROR", "No logits available after embedding processing - cannot generate");
            llama_sampler_free(sampler);
            llama_batch_free(gen_batch);
            return "";
        }

        // 使用 llama_sampler_sample 进行采样
        for (int i = 0; i < maxTokens; i++) {
            llama_token new_token;

            // 对于第一个 token，需要手动处理 logits
            // 因为 llama_sampler_sample 可能因为 n_outputs 问题崩溃
            if (i == 0) {
                // 获取最后一帧的 logits
                float* logits_ptr = llama_get_logits_ith(ctx_, -1);
                if (!logits_ptr) {
                    writeLog("ERROR", "Failed to get logits_ith at i=0");
                    break;
                }

                // 手动构建 candidates 并应用采样器
                const int32_t n_vocab = llama_vocab_n_tokens(vocab);
                std::vector<llama_token_data> candidates;
                candidates.resize(n_vocab);
                for (int32_t j = 0; j < n_vocab; j++) {
                    candidates[j].id = j;
                    candidates[j].logit = logits_ptr[j];
                    candidates[j].p = 0.0f;
                }

                llama_token_data_array cur_p = {
                    candidates.data(),
                    candidates.size(),
                    -1,
                    false
                };

                llama_sampler_apply(sampler, &cur_p);
                new_token = cur_p.data[cur_p.selected].id;
                writeLog("INFO", "Token %d sampled manually: %d", i, new_token);
            } else {
                // 后续 tokens 使用标准采样器接口
                // 先检查 logits 是否可用
                float* logits_check = llama_get_logits(ctx_);
                if (!logits_check) {
                    writeLog("ERROR", "No logits available at token %d - stopping generation", i);
                    break;
                }
                new_token = llama_sampler_sample(sampler, ctx_, -1);
                writeLog("INFO", "Token %d sampled via sampler: %d", i, new_token);
            }

            writeLog("DEBUG", "Checking EOS for token %d", i);
            if (llama_vocab_is_eog(vocab, new_token)) {
                writeLog("INFO", "EOS token at %d", i);
                break;
            }

            writeLog("DEBUG", "Pushing token %d to generated_tokens", i);
            generated_tokens.push_back(new_token);
            writeLog("DEBUG", "Calling llama_sampler_accept for token %d", i);
            llama_sampler_accept(sampler, new_token);
            writeLog("DEBUG", "sampler_accept done, preparing batch");

            gen_batch.token[0] = new_token;
            gen_batch.pos[0] = n_past++;
            gen_batch.n_seq_id[0] = 1;
            gen_batch.seq_id[0][0] = 0;
            gen_batch.logits[0] = 1;
            gen_batch.n_tokens = 1;

            writeLog("DEBUG", "Calling llama_decode for token %d", i);
            int32_t ret = llama_decode(ctx_, gen_batch);
            writeLog("DEBUG", "llama_decode returned %d", ret);
            if (ret != 0) {
                writeLog("ERROR", "llama_decode failed at %d: %d", i, ret);
                break;
            }

            // 每隔一段时间检查内存状态
            if (i > 0 && i % 50 == 0) {
                writeLog("INFO", "Generation progress: %d tokens, n_past=%d", i, n_past);
            }
        }

        llama_sampler_free(sampler);
        llama_batch_free(gen_batch);

        // 转换 tokens 为文本
        std::string result;
        for (llama_token token : generated_tokens) {
            char buf[16];
            int len = llama_token_to_piece(vocab, token, buf, sizeof(buf), 0, false);
            if (len > 0) {
                result.append(buf, len);
            }
        }

        auto endTime = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(endTime - startTime);

        tokenCount_ = static_cast<int>(generated_tokens.size());
        tokensPerSecond_ = duration.count() > 0 ?
            static_cast<float>(tokenCount_) * 1000.0f / static_cast<float>(duration.count()) : 0.0f;

        writeLog("INFO", "Generated %d tokens in %lldms (%.2f t/s)", tokenCount_, (long long)duration.count(), tokensPerSecond_);
        writeLog("INFO", "Caption result: %s", result.c_str());
        writeLog("INFO", "=== generateCaption RETURNING ===");
        OH_LOG_INFO(LOG_APP, "LlamaWrapper: Generated %{public}d tokens (%{public}.2f t/s)", tokenCount_, tokensPerSecond_);

        return result;
    }

    // 没有 mtmd 上下文，使用纯文本生成
    writeLog("WARN", "No mtmd context, falling back to text-only generation");
    std::string prompt = "请描述这张图片的内容。";
    std::string result = generate(prompt, maxTokens);

    return result;
}

void LlamaWrapper::clearGenerationMemory() {
    if (!ctx_) return;

    writeLog("INFO", "clearGenerationMemory: clearing KV cache");
    llama_memory_t mem = llama_get_memory(ctx_);
    if (mem) {
        llama_memory_clear(mem, true);
    }
    writeLog("INFO", "clearGenerationMemory: done");

    // 强制刷新日志
    if (logFile_) {
        fflush(logFile_);
    }
}

void LlamaWrapper::unload() {
    if (mtmdCtx_) {
        mtmd_free(mtmdCtx_);
        mtmdCtx_ = nullptr;
    }

    if (ctx_) {
        llama_free(ctx_);
        ctx_ = nullptr;
    }

    if (model_) {
        llama_free_model(model_);
        model_ = nullptr;
    }

    loaded_ = false;
    modelPath_.clear();
    mmprojPath_.clear();
    tokenCount_ = 0;
    tokensPerSecond_ = 0.0f;

    OH_LOG_INFO(LOG_APP, "LlamaWrapper: Model unloaded");
}