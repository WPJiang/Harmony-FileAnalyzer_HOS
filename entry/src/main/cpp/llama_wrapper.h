#ifndef LLAMA_WRAPPER_H
#define LLAMA_WRAPPER_H

#include <string>
#include <vector>
#include <cstdint>

// llama.cpp headers
#include "llama.h"
#include "mtmd.h"

// 前向声明日志回调函数
void llama_log_callback(ggml_log_level level, const char* text, void* user_data);

/**
 * llama.cpp 模型封装
 * 提供模型加载、文本生成、图片描述功能
 */
class LlamaWrapper {
public:
    LlamaWrapper();
    ~LlamaWrapper();

    /**
     * 加载 GGUF 模型
     * @param modelPath 模型文件路径
     * @param mmprojPath 多模态投影文件路径 (可选)
     * @return 是否加载成功
     */
    bool loadModel(const std::string& modelPath, const std::string& mmprojPath = "");

    /**
     * 检查模型是否已加载
     */
    bool isLoaded() const;

    /**
     * 检查是否支持多模态（图像）
     */
    bool supportsVision() const;

    /**
     * 生成文本
     * @param prompt 输入提示文本
     * @param maxTokens 最大生成 token 数
     * @return 生成的文本
     */
    std::string generate(const std::string& prompt, int maxTokens = 256);

    /**
     * 生成图片描述
     * @param imageData RGBA 图像数据
     * @param width 图像宽度
     * @param height 图像高度
     * @param maxTokens 最大生成 token 数
     * @return 图片描述文本
     */
    std::string generateCaption(
        const uint8_t* imageData,
        int width,
        int height,
        int maxTokens = 128
    );

    /**
     * 获取统计信息
     */
    int getTokenCount() const { return tokenCount_; }
    float getTokensPerSecond() const { return tokensPerSecond_; }

    /**
     * 清理生成后的内存 (KV cache)
     * 在生成完成后调用，减少内存占用
     */
    void clearGenerationMemory();

    /**
     * 设置日志文件路径 (独立文件日志，不依赖 hilog)
     * @param logPath 日志文件完整路径 (应用 filesDir 下的路径)
     */
    void setLogFile(const std::string& logPath);

    /**
     * 释放模型资源
     */
    void unload();

private:
    // 模型状态
    bool loaded_;
    std::string modelPath_;
    std::string mmprojPath_;
    int tokenCount_;
    float tokensPerSecond_;

    // llama.cpp 模型指针
    llama_model* model_;
    llama_context* ctx_;

    // MTMD 多模态上下文
    mtmd_context* mtmdCtx_;

    // 独立文件日志
    std::string logFilePath_;
    FILE* logFile_;

    // 内部日志方法
    void writeLog(const char* level, const char* format, ...);

    // 允许日志回调访问私有成员
    friend void llama_log_callback(ggml_log_level level, const char* text, void* user_data);
};

#endif // LLAMA_WRAPPER_H