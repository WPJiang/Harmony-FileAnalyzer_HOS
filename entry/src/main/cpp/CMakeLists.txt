cmake_minimum_required(VERSION 3.4.1)
project(llama_napi)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 添加定义
add_definitions(-D_GLIBCXX_USE_C99_MATH_TR1)

# llama.cpp 源文件 - 核心 GGML (新版结构)
set(GGML_SOURCES
    llama.cpp/ggml/src/ggml.c
    llama.cpp/ggml/src/ggml.cpp
    llama.cpp/ggml/src/ggml-quants.c
    llama.cpp/ggml/src/ggml-threading.cpp
    llama.cpp/ggml/src/ggml-backend.cpp
    llama.cpp/ggml/src/ggml-backend-reg.cpp
    llama.cpp/ggml/src/ggml-alloc.c
    llama.cpp/ggml/src/ggml-backend-dl.cpp
    llama.cpp/ggml/src/ggml-backend-meta.cpp
    llama.cpp/ggml/src/ggml-opt.cpp
    llama.cpp/ggml/src/gguf.cpp
)

# llama.cpp 源文件 - CPU 后端 (完整列表)
set(GGML_CPU_SOURCES
    llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c
    llama.cpp/ggml/src/ggml-cpu/ggml-cpu.cpp
    llama.cpp/ggml/src/ggml-cpu/quants.c
    llama.cpp/ggml/src/ggml-cpu/ops.cpp
    llama.cpp/ggml/src/ggml-cpu/binary-ops.cpp
    llama.cpp/ggml/src/ggml-cpu/unary-ops.cpp
    llama.cpp/ggml/src/ggml-cpu/repack.cpp
    llama.cpp/ggml/src/ggml-cpu/vec.cpp
    llama.cpp/ggml/src/ggml-cpu/traits.cpp
    llama.cpp/ggml/src/ggml-cpu/hbm.cpp
    llama.cpp/ggml/src/ggml-cpu/arch/arm/quants.c
    llama.cpp/ggml/src/ggml-cpu/arch/arm/repack.cpp
    llama.cpp/ggml/src/ggml-cpu/arch/arm/cpu-feats.cpp
)

# llama.cpp 源文件 - 核心推理
set(LLAMA_SOURCES
    llama.cpp/src/llama.cpp
    llama.cpp/src/llama-adapter.cpp
    llama.cpp/src/llama-arch.cpp
    llama.cpp/src/llama-batch.cpp
    llama.cpp/src/llama-chat.cpp
    llama.cpp/src/llama-context.cpp
    llama.cpp/src/llama-cparams.cpp
    llama.cpp/src/llama-grammar.cpp
    llama.cpp/src/llama-graph.cpp
    llama.cpp/src/llama-hparams.cpp
    llama.cpp/src/llama-impl.cpp
    llama.cpp/src/llama-io.cpp
    llama.cpp/src/llama-kv-cache.cpp
    llama.cpp/src/llama-kv-cache-iswa.cpp
    llama.cpp/src/llama-memory.cpp
    llama.cpp/src/llama-memory-hybrid.cpp
    llama.cpp/src/llama-memory-hybrid-iswa.cpp
    llama.cpp/src/llama-memory-recurrent.cpp
    llama.cpp/src/llama-mmap.cpp
    llama.cpp/src/llama-model.cpp
    llama.cpp/src/llama-model-loader.cpp
    llama.cpp/src/llama-model-saver.cpp
    llama.cpp/src/llama-quant.cpp
    llama.cpp/src/llama-sampler.cpp
    llama.cpp/src/llama-vocab.cpp
)

# llama.cpp 源文件 - 所有模型实现 (新版分模块)
set(LLAMA_MODEL_SOURCES
    llama.cpp/src/models/afmoe.cpp
    llama.cpp/src/models/apertus.cpp
    llama.cpp/src/models/arcee.cpp
    llama.cpp/src/models/arctic.cpp
    llama.cpp/src/models/arwkv7.cpp
    llama.cpp/src/models/baichuan.cpp
    llama.cpp/src/models/bailingmoe.cpp
    llama.cpp/src/models/bailingmoe2.cpp
    llama.cpp/src/models/bert.cpp
    llama.cpp/src/models/bitnet.cpp
    llama.cpp/src/models/bloom.cpp
    llama.cpp/src/models/chameleon.cpp
    llama.cpp/src/models/chatglm.cpp
    llama.cpp/src/models/codeshell.cpp
    llama.cpp/src/models/cogvlm.cpp
    llama.cpp/src/models/cohere2-iswa.cpp
    llama.cpp/src/models/command-r.cpp
    llama.cpp/src/models/dbrx.cpp
    llama.cpp/src/models/deci.cpp
    llama.cpp/src/models/deepseek.cpp
    llama.cpp/src/models/deepseek2.cpp
    llama.cpp/src/models/delta-net-base.cpp
    llama.cpp/src/models/dots1.cpp
    llama.cpp/src/models/dream.cpp
    llama.cpp/src/models/ernie4-5-moe.cpp
    llama.cpp/src/models/ernie4-5.cpp
    llama.cpp/src/models/eurobert.cpp
    llama.cpp/src/models/exaone-moe.cpp
    llama.cpp/src/models/exaone.cpp
    llama.cpp/src/models/exaone4.cpp
    llama.cpp/src/models/falcon-h1.cpp
    llama.cpp/src/models/falcon.cpp
    llama.cpp/src/models/gemma-embedding.cpp
    llama.cpp/src/models/gemma.cpp
    llama.cpp/src/models/gemma2-iswa.cpp
    llama.cpp/src/models/gemma3.cpp
    llama.cpp/src/models/gemma3n-iswa.cpp
    llama.cpp/src/models/gemma4-iswa.cpp
    llama.cpp/src/models/glm4-moe.cpp
    llama.cpp/src/models/glm4.cpp
    llama.cpp/src/models/gpt2.cpp
    llama.cpp/src/models/gptneox.cpp
    llama.cpp/src/models/granite-hybrid.cpp
    llama.cpp/src/models/granite.cpp
    llama.cpp/src/models/grok.cpp
    llama.cpp/src/models/grovemoe.cpp
    llama.cpp/src/models/hunyuan-dense.cpp
    llama.cpp/src/models/hunyuan-moe.cpp
    llama.cpp/src/models/internlm2.cpp
    llama.cpp/src/models/jais.cpp
    llama.cpp/src/models/jais2.cpp
    llama.cpp/src/models/jamba.cpp
    llama.cpp/src/models/kimi-linear.cpp
    llama.cpp/src/models/lfm2.cpp
    llama.cpp/src/models/llada-moe.cpp
    llama.cpp/src/models/llada.cpp
    llama.cpp/src/models/llama-iswa.cpp
    llama.cpp/src/models/llama.cpp
    llama.cpp/src/models/maincoder.cpp
    llama.cpp/src/models/mamba-base.cpp
    llama.cpp/src/models/mamba.cpp
    llama.cpp/src/models/mimo2-iswa.cpp
    llama.cpp/src/models/minicpm3.cpp
    llama.cpp/src/models/minimax-m2.cpp
    llama.cpp/src/models/mistral3.cpp
    llama.cpp/src/models/modern-bert.cpp
    llama.cpp/src/models/mpt.cpp
    llama.cpp/src/models/nemotron-h.cpp
    llama.cpp/src/models/nemotron.cpp
    llama.cpp/src/models/neo-bert.cpp
    llama.cpp/src/models/olmo.cpp
    llama.cpp/src/models/olmo2.cpp
    llama.cpp/src/models/olmoe.cpp
    llama.cpp/src/models/openai-moe-iswa.cpp
    llama.cpp/src/models/openelm.cpp
    llama.cpp/src/models/orion.cpp
    llama.cpp/src/models/paddleocr.cpp
    llama.cpp/src/models/pangu-embedded.cpp
    llama.cpp/src/models/phi2.cpp
    llama.cpp/src/models/phi3.cpp
    llama.cpp/src/models/plamo.cpp
    llama.cpp/src/models/plamo2.cpp
    llama.cpp/src/models/plamo3.cpp
    llama.cpp/src/models/plm.cpp
    llama.cpp/src/models/qwen.cpp
    llama.cpp/src/models/qwen2.cpp
    llama.cpp/src/models/qwen2moe.cpp
    llama.cpp/src/models/qwen2vl.cpp
    llama.cpp/src/models/qwen3.cpp
    llama.cpp/src/models/qwen35.cpp
    llama.cpp/src/models/qwen35moe.cpp
    llama.cpp/src/models/qwen3moe.cpp
    llama.cpp/src/models/qwen3next.cpp
    llama.cpp/src/models/qwen3vl-moe.cpp
    llama.cpp/src/models/qwen3vl.cpp
    llama.cpp/src/models/refact.cpp
    llama.cpp/src/models/rnd1.cpp
    llama.cpp/src/models/rwkv6-base.cpp
    llama.cpp/src/models/rwkv6.cpp
    llama.cpp/src/models/rwkv6qwen2.cpp
    llama.cpp/src/models/rwkv7-base.cpp
    llama.cpp/src/models/rwkv7.cpp
    llama.cpp/src/models/seed-oss.cpp
    llama.cpp/src/models/smallthinker.cpp
    llama.cpp/src/models/smollm3.cpp
    llama.cpp/src/models/stablelm.cpp
    llama.cpp/src/models/starcoder.cpp
    llama.cpp/src/models/starcoder2.cpp
    llama.cpp/src/models/step35-iswa.cpp
    llama.cpp/src/models/t5-dec.cpp
    llama.cpp/src/models/t5-enc.cpp
    llama.cpp/src/models/wavtokenizer-dec.cpp
    llama.cpp/src/models/xverse.cpp
)

# Unicode 支持
set(UNICODE_SOURCES
    llama.cpp/src/unicode.cpp
    llama.cpp/src/unicode-data.cpp
)

# MTMD 多模态支持 (图像处理)
set(MTMD_SOURCES
    llama.cpp/tools/mtmd/mtmd.cpp
    llama.cpp/tools/mtmd/mtmd-helper.cpp
    llama.cpp/tools/mtmd/mtmd-image.cpp
    llama.cpp/tools/mtmd/mtmd-audio.cpp
    llama.cpp/tools/mtmd/clip.cpp
    llama.cpp/tools/mtmd/debug/mtmd-debug.cpp
    llama.cpp/tools/mtmd/models/qwen2vl.cpp
    llama.cpp/tools/mtmd/models/qwen3vl.cpp
    llama.cpp/tools/mtmd/models/siglip.cpp
    llama.cpp/tools/mtmd/models/internvl.cpp
    llama.cpp/tools/mtmd/models/minicpmv.cpp
    llama.cpp/tools/mtmd/models/pixtral.cpp
    llama.cpp/tools/mtmd/models/gemma4v.cpp
    llama.cpp/tools/mtmd/models/llava.cpp
    llama.cpp/tools/mtmd/models/llama4.cpp
    llama.cpp/tools/mtmd/models/step3vl.cpp
    llama.cpp/tools/mtmd/models/cogvlm.cpp
    llama.cpp/tools/mtmd/models/mobilenetv5.cpp
    llama.cpp/tools/mtmd/models/dotsocr.cpp
    llama.cpp/tools/mtmd/models/paddleocr.cpp
    llama.cpp/tools/mtmd/models/nemotron-v2-vl.cpp
    llama.cpp/tools/mtmd/models/kimivl.cpp
    llama.cpp/tools/mtmd/models/kimik25.cpp
    llama.cpp/tools/mtmd/models/glm4v.cpp
    llama.cpp/tools/mtmd/models/hunyuanocr.cpp
    llama.cpp/tools/mtmd/models/deepseekocr.cpp
    llama.cpp/tools/mtmd/models/conformer.cpp
    llama.cpp/tools/mtmd/models/whisper-enc.cpp
    llama.cpp/tools/mtmd/models/qwen3a.cpp
    llama.cpp/tools/mtmd/models/gemma4a.cpp
    llama.cpp/tools/mtmd/models/youtuvl.cpp
)

# Common 工具库 (mtmd 依赖 - 简化版，不含HTTP下载功能)
set(COMMON_SOURCES
    llama.cpp/common/arg.cpp
    llama.cpp/common/build-info.cpp
    llama.cpp/common/chat.cpp
    llama.cpp/common/chat-auto-parser-helpers.cpp
    llama.cpp/common/chat-auto-parser-generator.cpp
    llama.cpp/common/chat-diff-analyzer.cpp
    llama.cpp/common/chat-peg-parser.cpp
    llama.cpp/common/common.cpp
    llama.cpp/common/console.cpp
    llama.cpp/common/debug.cpp
    llama.cpp/common/download_stub.cpp
    llama.cpp/common/json-partial.cpp
    llama.cpp/common/json-schema-to-grammar.cpp
    llama.cpp/common/llguidance.cpp
    llama.cpp/common/log.cpp
    llama.cpp/common/ngram-cache.cpp
    llama.cpp/common/ngram-map.cpp
    llama.cpp/common/ngram-mod.cpp
    llama.cpp/common/peg-parser.cpp
    llama.cpp/common/preset.cpp
    llama.cpp/common/regex-partial.cpp
    llama.cpp/common/reasoning-budget.cpp
    llama.cpp/common/sampling.cpp
    llama.cpp/common/speculative.cpp
    llama.cpp/common/unicode.cpp
    # jinja 模板引擎
    llama.cpp/common/jinja/caps.cpp
    llama.cpp/common/jinja/lexer.cpp
    llama.cpp/common/jinja/parser.cpp
    llama.cpp/common/jinja/runtime.cpp
    llama.cpp/common/jinja/string.cpp
    llama.cpp/common/jinja/value.cpp
)

# NAPI 源文件
set(NAPI_SOURCES
    llama_napi.cpp
    llama_wrapper.cpp
)

# 创建共享库
add_library(llama_napi SHARED
    ${GGML_SOURCES}
    ${GGML_CPU_SOURCES}
    ${LLAMA_SOURCES}
    ${LLAMA_MODEL_SOURCES}
    ${UNICODE_SOURCES}
    ${MTMD_SOURCES}
    ${COMMON_SOURCES}
    ${NAPI_SOURCES}
)

# 包含目录
include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/include
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/ggml/include
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/ggml/src
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/common
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/src
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/src/models
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/ggml/src/ggml-cpu
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/ggml/src/ggml-cpu/arch/arm
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/tools/mtmd
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/tools/mtmd/models
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/vendor/stb
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/vendor/miniaudio
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/vendor
)

# 编译定义
target_compile_definitions(llama_napi PRIVATE
    GGML_USE_CPU
    _GNU_SOURCE
    GGML_VERSION="b4500"
    GGML_COMMIT="unknown"
)

# 链接库
target_link_libraries(llama_napi
    libace_napi.z.so
    libhilog_ndk.z.so
    librawfile.z.so
)

# 编译选项
target_compile_options(llama_napi PRIVATE
    -fvisibility=hidden
    -ffunction-sections
    -fdata-sections
    -O2
)

# C 文件编译选项
set_source_files_properties(
    llama.cpp/ggml/src/ggml.c
    llama.cpp/ggml/src/ggml-quants.c
    llama.cpp/ggml/src/ggml-cpu/ggml-cpu.c
    llama.cpp/ggml/src/ggml-cpu/quants.c
    llama.cpp/ggml/src/ggml-cpu/arch/arm/quants.c
    PROPERTIES COMPILE_FLAGS "-O3 -Wno-unused-variable -Wno-unused-function"
)