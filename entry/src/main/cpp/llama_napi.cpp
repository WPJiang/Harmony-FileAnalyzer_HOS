/**
 * llama.cpp NAPI 绑定
 * 使用 LlamaWrapper 封装 llama.cpp 功能
 */

#include <napi/native_api.h>
#include <hilog/log.h>
#include <string>
#include <cstring>
#include <cstdio>
#include <ctime>
#include "llama_wrapper.h"

// 全局 wrapper 实例
static LlamaWrapper* g_wrapper = nullptr;

// 全局日志文件（NAPI 层专用）
static FILE* g_napiLogFile = nullptr;

// 日志宏
#define LOG_TAG "LlamaNapi"
#define LOG_DOMAIN 0x03D00

// NAPI 层专用日志函数
static void napiWriteLog(const char* level, const char* format, ...) {
    if (!g_napiLogFile) return;

    time_t now = time(nullptr);
    struct tm* tm_info = localtime(&now);
    char timeBuf[32];
    strftime(timeBuf, sizeof(timeBuf), "%H:%M:%S", tm_info);

    va_list args;
    va_start(args, format);

    fprintf(g_napiLogFile, "[%s] [%s] ", timeBuf, level);
    vfprintf(g_napiLogFile, format, args);
    fprintf(g_napiLogFile, "\n");
    fflush(g_napiLogFile);

    va_end(args);
}

/**
 * 加载模型
 * args[0]: modelPath (string)
 * args[1]: mmprojPath (string, optional)
 */
static napi_value LoadModel(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 获取模型路径
    char modelPath[512] = {0};
    size_t modelPathLen = 0;
    if (argc > 0) {
        napi_get_value_string_utf8(env, args[0], modelPath, sizeof(modelPath), &modelPathLen);
    }

    // 获取 mmproj 路径
    char mmprojPath[512] = {0};
    size_t mmprojLen = 0;
    if (argc > 1) {
        napi_get_value_string_utf8(env, args[1], mmprojPath, sizeof(mmprojPath), &mmprojLen);
    }

    OH_LOG_INFO(LOG_APP, "LlamaNapi: LoadModel called, model=%{public}s mmproj=%{public}s",
                modelPath, mmprojPath);

    // 创建或重用 wrapper
    if (!g_wrapper) {
        g_wrapper = new LlamaWrapper();
    }

    // 加载模型
    bool result = g_wrapper->loadModel(modelPath, std::string(mmprojPath));

    napi_value returnValue;
    napi_get_boolean(env, result, &returnValue);
    return returnValue;
}

/**
 * 检查模型是否加载
 */
static napi_value IsLoaded(napi_env env, napi_callback_info info) {
    napi_value returnValue;
    bool loaded = g_wrapper && g_wrapper->isLoaded();
    napi_get_boolean(env, loaded, &returnValue);
    return returnValue;
}

/**
 * 卸载模型
 */
static napi_value UnloadModel(napi_env env, napi_callback_info info) {
    OH_LOG_INFO(LOG_APP, "LlamaNapi: UnloadModel called");

    if (g_wrapper) {
        g_wrapper->unload();
        delete g_wrapper;
        g_wrapper = nullptr;
    }

    napi_value returnValue;
    napi_get_boolean(env, true, &returnValue);
    return returnValue;
}

/**
 * 生成文本
 * args[0]: prompt (string)
 * args[1]: maxTokens (int32, optional)
 */
static napi_value Generate(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (!g_wrapper || !g_wrapper->isLoaded()) {
        OH_LOG_ERROR(LOG_APP, "LlamaNapi: Model not loaded");
        napi_value empty;
        napi_create_string_utf8(env, "", 0, &empty);
        return empty;
    }

    // 获取 prompt
    size_t promptLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &promptLen);
    std::string prompt(promptLen + 1, '\0');
    napi_get_value_string_utf8(env, args[0], &prompt[0], promptLen + 1, &promptLen);
    prompt.resize(promptLen);

    // 获取 maxTokens
    int maxTokens = 256;
    if (argc > 1) {
        napi_get_value_int32(env, args[1], &maxTokens);
    }

    OH_LOG_INFO(LOG_APP, "LlamaNapi: Generate called, prompt_len=%{public}zu maxTokens=%{public}d",
                promptLen, maxTokens);

    // 生成文本
    std::string result = g_wrapper->generate(prompt, maxTokens);

    napi_value returnValue;
    napi_create_string_utf8(env, result.c_str(), result.length(), &returnValue);
    return returnValue;
}

/**
 * 生成图片描述
 * args[0]: imageData (ArrayBuffer)
 * args[1]: width (int32)
 * args[2]: height (int32)
 * args[3]: maxTokens (int32, optional)
 */
static napi_value GenerateCaption(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (!g_wrapper || !g_wrapper->isLoaded()) {
        OH_LOG_ERROR(LOG_APP, "LlamaNapi: Model not loaded for caption");
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    // 获取图像数据
    void* imageData = nullptr;
    size_t imageLength = 0;
    bool isArrayBuffer = false;
    napi_is_arraybuffer(env, args[0], &isArrayBuffer);
    if (isArrayBuffer) {
        napi_get_arraybuffer_info(env, args[0], &imageData, &imageLength);
    }

    // 获取图像尺寸
    int32_t width = 0;
    napi_get_value_int32(env, args[1], &width);

    int32_t height = 0;
    napi_get_value_int32(env, args[2], &height);

    // 获取 maxTokens
    int maxTokens = 128;
    if (argc > 3) {
        napi_get_value_int32(env, args[3], &maxTokens);
    }

    OH_LOG_INFO(LOG_APP, "LlamaNapi: GenerateCaption called, imageLen=%{public}zu width=%{public}d height=%{public}d",
                imageLength, width, height);
    napiWriteLog("INFO", "GenerateCaption: imageLen=%zu, width=%d, height=%d, maxTokens=%d",
                 imageLength, width, height, maxTokens);

    // 生成描述
    std::string caption = g_wrapper->generateCaption(
        static_cast<const uint8_t*>(imageData),
        width,
        height,
        maxTokens
    );

    OH_LOG_INFO(LOG_APP, "LlamaNapi: Caption generated, len=%{public}zu", caption.length());
    napiWriteLog("INFO", "Caption generated, len=%zu", caption.length());

    // 创建返回对象
    napi_value result;
    napi_status status = napi_create_object(env, &result);
    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "LlamaNapi: Failed to create result object");
        napiWriteLog("ERROR", "Failed to create result object, status=%d", status);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }
    OH_LOG_INFO(LOG_APP, "LlamaNapi: Result object created");
    napiWriteLog("INFO", "Result object created");

    // caption 字段 - 使用 napi_create_string_utf8_with_length 避免长字符串问题
    napi_value captionValue;
    size_t captionLen = caption.length();
    // 限制返回字符串长度，防止 NAPI 处理长字符串崩溃
    const size_t MAX_CAPTION_LEN = 256;  // 进一步减少到 256
    if (captionLen > MAX_CAPTION_LEN) {
        captionLen = MAX_CAPTION_LEN;
        napiWriteLog("INFO", "Caption truncated from %zu to %zu", caption.length(), captionLen);
    }

    // 使用 new 分配临时字符串，确保内存对齐
    char* captionBuffer = new char[captionLen + 1];
    memcpy(captionBuffer, caption.c_str(), captionLen);
    captionBuffer[captionLen] = '\0';

    OH_LOG_INFO(LOG_APP, "LlamaNapi: Creating string with len=%{public}zu", captionLen);
    napiWriteLog("INFO", "Creating napi string with len=%zu", captionLen);
    status = napi_create_string_utf8(env, captionBuffer, captionLen, &captionValue);
    delete[] captionBuffer;  // 立即释放临时缓冲区

    if (status != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "LlamaNapi: Failed to create caption string");
        napiWriteLog("ERROR", "Failed to create caption string, status=%d", status);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }
    OH_LOG_INFO(LOG_APP, "LlamaNapi: Caption string created");
    napiWriteLog("INFO", "Caption string created");

    napi_set_named_property(env, result, "caption", captionValue);
    OH_LOG_INFO(LOG_APP, "LlamaNapi: caption property set");
    napiWriteLog("INFO", "caption property set");

    // tokensPerSecond 字段
    napi_value tpsValue;
    napi_create_double(env, g_wrapper->getTokensPerSecond(), &tpsValue);
    napi_set_named_property(env, result, "tokensPerSecond", tpsValue);
    OH_LOG_INFO(LOG_APP, "LlamaNapi: tokensPerSecond property set");
    napiWriteLog("INFO", "tokensPerSecond property set");

    // tokenCount 字段
    napi_value countValue;
    napi_create_int32(env, g_wrapper->getTokenCount(), &countValue);
    napi_set_named_property(env, result, "tokenCount", countValue);
    OH_LOG_INFO(LOG_APP, "LlamaNapi: tokenCount property set, returning result");
    napiWriteLog("INFO", "=== GenerateCaption RETURNING SUCCESS ===");

    // 清理生成后的内存 (KV cache)，减少内存压力
    if (g_wrapper) {
        g_wrapper->clearGenerationMemory();
        napiWriteLog("INFO", "Generation memory cleared after return");
    }

    return result;
}

/**
 * 异步生成图片描述 - 使用 napi_create_async_work 在子线程执行推理
 * 避免阻塞主线程导致 ANR
 */

// 异步工作数据
struct CaptionAsyncData {
    napi_async_work work;
    napi_deferred deferred;

    // 输入参数
    std::vector<uint8_t> imageData;
    int width;
    int height;
    int maxTokens;

    // 输出结果
    std::string caption;
    float tokensPerSecond;
    int tokenCount;
    bool success;
    std::string errorMsg;
};

static void CaptionAsyncExecute(napi_env env, void* data) {
    CaptionAsyncData* asyncData = static_cast<CaptionAsyncData*>(data);

    napiWriteLog("INFO", "CaptionAsyncExecute: starting on worker thread");

    if (!g_wrapper || !g_wrapper->isLoaded()) {
        asyncData->success = false;
        asyncData->errorMsg = "Model not loaded";
        napiWriteLog("ERROR", "CaptionAsyncExecute: model not loaded");
        return;
    }

    try {
        std::string result = g_wrapper->generateCaption(
            asyncData->imageData.data(),
            asyncData->width,
            asyncData->height,
            asyncData->maxTokens
        );

        asyncData->caption = result;
        asyncData->tokensPerSecond = g_wrapper->getTokensPerSecond();
        asyncData->tokenCount = g_wrapper->getTokenCount();
        asyncData->success = true;

        napiWriteLog("INFO", "CaptionAsyncExecute: done, caption len=%zu", result.length());
    } catch (const std::exception& e) {
        asyncData->success = false;
        asyncData->errorMsg = std::string("Exception: ") + e.what();
        napiWriteLog("ERROR", "CaptionAsyncExecute exception: %s", e.what());
    }

    // 清理生成内存
    if (g_wrapper) {
        g_wrapper->clearGenerationMemory();
    }
}

static void CaptionAsyncComplete(napi_env env, napi_status status, void* data) {
    CaptionAsyncData* asyncData = static_cast<CaptionAsyncData*>(data);

    napiWriteLog("INFO", "CaptionAsyncComplete: status=%d, success=%d", status, asyncData->success);

    if (status != napi_ok || !asyncData->success) {
        // 返回错误
        napi_value error;
        std::string msg = asyncData->errorMsg.empty() ? "Unknown error" : asyncData->errorMsg;
        napi_create_string_utf8(env, msg.c_str(), msg.length(), &error);
        napi_reject_deferred(env, asyncData->deferred, error);
    } else {
        // 创建返回对象
        napi_value result;
        napi_create_object(env, &result);

        // caption
        napi_value captionValue;
        size_t captionLen = asyncData->caption.length();
        const size_t MAX_LEN = 512;
        if (captionLen > MAX_LEN) captionLen = MAX_LEN;

        char* buf = new char[captionLen + 1];
        memcpy(buf, asyncData->caption.c_str(), captionLen);
        buf[captionLen] = '\0';
        napi_create_string_utf8(env, buf, captionLen, &captionValue);
        delete[] buf;

        napi_set_named_property(env, result, "caption", captionValue);

        // tokensPerSecond
        napi_value tpsValue;
        napi_create_double(env, asyncData->tokensPerSecond, &tpsValue);
        napi_set_named_property(env, result, "tokensPerSecond", tpsValue);

        // tokenCount
        napi_value countValue;
        napi_create_int32(env, asyncData->tokenCount, &countValue);
        napi_set_named_property(env, result, "tokenCount", countValue);

        napi_resolve_deferred(env, asyncData->deferred, result);
        napiWriteLog("INFO", "CaptionAsyncComplete: resolved promise");
    }

    // 清理
    napi_delete_async_work(env, asyncData->work);
    delete asyncData;
}

static napi_value GenerateCaptionAsync(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napiWriteLog("INFO", "GenerateCaptionAsync called");

    // 创建异步数据
    CaptionAsyncData* asyncData = new CaptionAsyncData();
    asyncData->success = false;
    asyncData->tokensPerSecond = 0;
    asyncData->tokenCount = 0;

    // 获取图像数据
    void* imageData = nullptr;
    size_t imageLength = 0;
    bool isArrayBuffer = false;
    napi_is_arraybuffer(env, args[0], &isArrayBuffer);
    if (isArrayBuffer) {
        napi_get_arraybuffer_info(env, args[0], &imageData, &imageLength);
    }

    // 复制图像数据（异步执行时原 buffer 可能被释放）
    if (imageData && imageLength > 0) {
        asyncData->imageData.assign(
            static_cast<uint8_t*>(imageData),
            static_cast<uint8_t*>(imageData) + imageLength
        );
    }

    // 获取参数
    napi_get_value_int32(env, args[1], &asyncData->width);
    napi_get_value_int32(env, args[2], &asyncData->height);
    asyncData->maxTokens = 128;
    if (argc > 3) {
        napi_get_value_int32(env, args[3], &asyncData->maxTokens);
    }

    napiWriteLog("INFO", "GenerateCaptionAsync: w=%d h=%d dataLen=%zu maxTokens=%d",
                 asyncData->width, asyncData->height, imageLength, asyncData->maxTokens);

    // 创建 Promise
    napi_value promise;
    napi_create_promise(env, &asyncData->deferred, &promise);

    // 创建异步工作
    napi_value resourceName;
    napi_create_string_utf8(env, "GenerateCaptionAsync", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName,
                           CaptionAsyncExecute, CaptionAsyncComplete,
                           asyncData, &asyncData->work);

    // 加入队列
    napi_queue_async_work(env, asyncData->work);

    return promise;
}

/**
 * 清理生成内存 (手动调用)
 */
static napi_value ClearMemory(napi_env env, napi_callback_info info) {
    if (g_wrapper) {
        g_wrapper->clearGenerationMemory();
        OH_LOG_INFO(LOG_APP, "LlamaNapi: Memory cleared");
    }

    napi_value returnValue;
    napi_get_boolean(env, true, &returnValue);
    return returnValue;
}

/**
 * 获取模型信息
 */
static napi_value GetModelInfo(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_object(env, &result);

    // loaded 字段
    napi_value loadedValue;
    napi_get_boolean(env, g_wrapper && g_wrapper->isLoaded(), &loadedValue);
    napi_set_named_property(env, result, "loaded", loadedValue);

    // modelPath 字段 (如果已加载)
    napi_value pathValue;
    if (g_wrapper && g_wrapper->isLoaded()) {
        // 返回一个占位路径，实际路径在 wrapper 内部
        napi_create_string_utf8(env, "model_loaded", 12, &pathValue);
    } else {
        napi_create_string_utf8(env, "", 0, &pathValue);
    }
    napi_set_named_property(env, result, "modelPath", pathValue);

    return result;
}

/**
 * 设置日志文件 (独立文件日志，不依赖 hilog)
 * args[0]: logPath (string) - 应用 filesDir 下的日志文件路径
 */
static napi_value SetLogFile(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 如果 wrapper 不存在，先创建它
    if (!g_wrapper) {
        OH_LOG_INFO(LOG_APP, "LlamaNapi: Creating wrapper for SetLogFile");
        g_wrapper = new LlamaWrapper();
    }

    // 获取日志文件路径
    char logPath[512] = {0};
    size_t logPathLen = 0;
    if (argc > 0) {
        napi_get_value_string_utf8(env, args[0], logPath, sizeof(logPath), &logPathLen);
    }

    OH_LOG_INFO(LOG_APP, "LlamaNapi: SetLogFile called, path=%{public}s", logPath);

    // 设置 wrapper 日志文件
    g_wrapper->setLogFile(std::string(logPath));

    // 同时打开 NAPI 层的日志文件（使用同一个文件）
    if (g_napiLogFile) {
        fclose(g_napiLogFile);
    }
    g_napiLogFile = fopen(logPath, "a");
    if (g_napiLogFile) {
        napiWriteLog("INFO", "=== NAPI log initialized ===");
    }

    napi_value returnValue;
    napi_get_boolean(env, true, &returnValue);
    return returnValue;
}

/**
 * 模块初始化
 */
EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    OH_LOG_INFO(LOG_APP, "LlamaNapi: Module initializing");

    napi_property_descriptor desc[] = {
        {"loadModel", nullptr, LoadModel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isLoaded", nullptr, IsLoaded, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"unloadModel", nullptr, UnloadModel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"generate", nullptr, Generate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"generateCaption", nullptr, GenerateCaption, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"generateCaptionAsync", nullptr, GenerateCaptionAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getModelInfo", nullptr, GetModelInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setLogFile", nullptr, SetLogFile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clearMemory", nullptr, ClearMemory, nullptr, nullptr, nullptr, napi_default, nullptr},
    };

    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

// HarmonyOS NAPI 模块定义
static napi_module llamaNapiModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "llama_napi",
    .nm_priv = nullptr,
    .reserved = {0},
};

// 模块注册 - 使用 constructor 确保在 SO 加载时自动注册
extern "C" __attribute__((constructor)) void RegisterLlamaNapiModule() {
    OH_LOG_INFO(LOG_APP, "LlamaNapi: Constructor - registering module");
    napi_module_register(&llamaNapiModule);
}