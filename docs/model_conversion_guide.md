# Sentence-Transformers模型转MindSpore Lite (.ms) 格式指南

> 将 `paraphrase-multilingual-MiniLM-L12-v2` 模型转换为HarmonyOS手机可使用的 `.ms` 格式

---

## 概述

**目标模型:** `paraphrase-multilingual-MiniLM-L12-v2`
- 原始框架: PyTorch (sentence-transformers)
- 模型架构: BERT (384维隐藏层)
- 输入: 文本token序列
- 输出: 384维句向量

**转换路径:**
```
PyTorch (.pt/safetensors) → ONNX (.onnx) → MindSpore Lite (.ms)
```

---

## 第一步: 环境准备

### 1.1 安装必要的Python包

```bash
# 创建转换环境
conda create -n model_convert python=3.10
conda activate model_convert

# 安装依赖
pip install torch onnx onnxruntime transformers sentence-transformers
pip install mindspore-lite  # MindSpore Lite转换工具
```

### 1.2 下载MindSpore Lite Converter工具

从华为官网下载转换工具:
- [MindSpore Lite Converter下载页面](https://www.mindspore.cn/lite/docs/zh-CN/master/use/converter_tool.html)

Windows版本下载:
```bash
# 下载 converter_lite Windows版本
# 解压到: C:\mindspore-lite-tools\
```

---

## 第二步: 导出PyTorch模型为ONNX格式

### 2.1 创建导出脚本

创建文件 `export_to_onnx.py`:

```python
#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
将sentence-transformers模型导出为ONNX格式
"""

import torch
import onnx
from sentence_transformers import SentenceTransformer
import os

def export_sentence_transformer_to_onnx(
    model_path: str,
    output_path: str,
    max_seq_length: int = 128,  # 手机端建议使用较短序列
    opset_version: int = 12
):
    """
    导出sentence-transformers模型为ONNX
    
    Args:
        model_path: 原模型路径
        output_path: ONNX输出路径
        max_seq_length: 最大序列长度
        opset_version: ONNX算子版本
    """
    
    # 加载模型
    print(f"加载模型: {model_path}")
    model = SentenceTransformer(model_path)
    
    # 获取BERT模块
    bert_model = model[0]  # Transformer模块
    pooling_model = model[1]  # Pooling模块
    
    # 设置序列长度
    bert_model.max_seq_length = max_seq_length
    
    # 创建dummy输入
    # BERT输入: input_ids, attention_mask, token_type_ids
    dummy_input_ids = torch.zeros(1, max_seq_length, dtype=torch.long)
    dummy_attention_mask = torch.ones(1, max_seq_length, dtype=torch.long)
    dummy_token_type_ids = torch.zeros(1, max_seq_length, dtype=torch.long)
    
    # 构建完整的推理函数
    class FullModel(torch.nn.Module):
        def __init__(self, transformer, pooling):
            super().__init__()
            self.transformer = transformer
            self.pooling = pooling
        
        def forward(self, input_ids, attention_mask, token_type_ids):
            # Transformer输出
            transformer_output = self.transformer({
                'input_ids': input_ids,
                'attention_mask': attention_mask,
                'token_type_ids': token_type_ids
            })
            
            # Pooling输出 - 提取sentence embedding
            # sentence_transformers的输出是字典
            token_embeddings = transformer_output['token_embeddings']
            
            # Mean pooling
            input_mask_expanded = attention_mask.unsqueeze(-1).expand(token_embeddings.size()).float()
            sum_embeddings = torch.sum(token_embeddings * input_mask_expanded, 1)
            sum_mask = torch.clamp(input_mask_expanded.sum(1), min=1e-9)
            output = sum_embeddings / sum_mask
            
            return output
    
    full_model = FullModel(bert_model.auto_model, pooling_model)
    full_model.eval()
    
    # 导出ONNX
    print(f"导出ONNX到: {output_path}")
    
    torch.onnx.export(
        full_model,
        (dummy_input_ids, dummy_attention_mask, dummy_token_type_ids),
        output_path,
        input_names=['input_ids', 'attention_mask', 'token_type_ids'],
        output_names=['sentence_embedding'],
        dynamic_axes={
            'input_ids': {0: 'batch_size', 1: 'sequence_length'},
            'attention_mask': {0: 'batch_size', 1: 'sequence_length'},
            'token_type_ids': {0: 'batch_size', 1: 'sequence_length'},
            'sentence_embedding': {0: 'batch_size'}
        },
        opset_version=opset_version,
        do_constant_folding=True
    )
    
    # 验证ONNX模型
    print("验证ONNX模型...")
    onnx_model = onnx.load(output_path)
    onnx.checker.check_model(onnx_model)
    print("ONNX模型验证通过!")
    
    # 测试推理
    import onnxruntime as ort
    session = ort.InferenceSession(output_path)
    
    outputs = session.run(
        ['sentence_embedding'],
        {
            'input_ids': dummy_input_ids.numpy(),
            'attention_mask': dummy_attention_mask.numpy(),
            'token_type_ids': dummy_token_type_ids.numpy()
        }
    )
    
    print(f"输出向量维度: {outputs[0].shape}")
    
    return output_path


if __name__ == "__main__":
    # 使用本地模型路径
    model_path = "D:/jiangweipeng/trae_code/file_analyzer/models/paraphrase-multilingual-MiniLM-L12-v2"
    output_path = "text_embedding.onnx"
    
    export_sentence_transformer_to_onnx(
        model_path=model_path,
        output_path=output_path,
        max_seq_length=128,  # 手机端建议128或64
        opset_version=12
    )
    
    print(f"ONNX导出完成: {output_path}")
```

### 2.2 执行导出

```bash
cd D:\jiangweipeng\Harmony\FileAnalyzer_HOS
python export_to_onnx.py
```

**预期输出:**
```
加载模型: D:/jiangweipeng/trae_code/file_analyzer/models/paraphrase-multilingual-MiniLM-L12-v2
导出ONNX到: text_embedding.onnx
ONNX模型验证通过!
输出向量维度: (1, 384)
ONNX导出完成: text_embedding.onnx
```

---

## 第三步: 准备词表文件

### 3.1 提取tokenizer文件

模型需要的tokenizer文件:
- `vocab.txt` - 词表
- `tokenizer_config.json` - tokenizer配置

```bash
# 复制tokenizer文件到HarmonyOS项目
cp "D:/jiangweipeng/trae_code/file_analyzer/models/paraphrase-multilingual-MiniLM-L12-v2/vocab.txt" \
   "D:/jiangweipeng/Harmony/FileAnalyzer_HOS/entry/src/main/resources/rawfile/vocab.txt"
```

### 3.2 创建简化词表 (可选，减小体积)

如果词表太大(250037词)，可以创建简化版本:

```python
# create_vocab_subset.py
import json

# 常用中文词 + 特殊token
essential_tokens = [
    "[PAD]", "[UNK]", "[CLS]", "[SEP]", "[MASK]",
    # 常用中文字符 (按需扩展)
]

# 加载原词表
with open("vocab.txt", "r", encoding="utf-8") as f:
    vocab = {}
    for line in f:
        token, idx = line.strip().split("\t") if "\t" in line else (line.strip(), len(vocab))
        vocab[token] = int(idx)

# 筛选常用词
subset_vocab = {}
for token in essential_tokens:
    if token in vocab:
        subset_vocab[token] = len(subset_vocab)

# 写入简化词表
with open("vocab_small.txt", "w", encoding="utf-8") as f:
    for token, idx in subset_vocab.items():
        f.write(f"{token}\t{idx}\n")
```

---

## 第四步: ONNX转MindSpore Lite (.ms) 格式

### 4.1 使用MindSpore Lite Converter

**Windows命令行:**

```bash
# 假设converter_lite工具在 C:\mindspore-lite-tools\
cd C:\mindspore-lite-tools\

# 基础转换命令
converter_lite.exe \
    --fmk=ONNX \
    --modelFile=D:\jiangweipeng\Harmony\FileAnalyzer_HOS\text_embedding.onnx \
    --outputFile=D:\jiangweipeng\Harmony\FileAnalyzer_HOS\text_embedding \
    --inputShape="input_ids:1,128;attention_mask:1,128;token_type_ids:1,128"
```

### 4.2 优化参数 (可选)

```bash
# FP16量化 (减小模型体积，适合手机)
converter_lite.exe \
    --fmk=ONNX \
    --modelFile=text_embedding.onnx \
    --outputFile=text_embedding_fp16 \
    --inputShape="input_ids:1,128;attention_mask:1,128;token_type_ids:1,128" \
    --fp16=true

# 无量纲输入 (支持动态batch)
converter_lite.exe \
    --fmk=ONNX \
    --modelFile=text_embedding.onnx \
    --outputFile=text_embedding_dynamic \
    --inputShape="input_ids:-1,128;attention_mask:-1,128;token_type_ids:-1,128"
```

### 4.3 验证.ms模型

```python
# 验证MindSpore Lite模型
import mindspore_lite as msl

# 加载模型
model = msl.Model()
model.build_from_file("text_embedding.ms")

# 创建输入
inputs = model.create_inputs()
inputs[0].set_data([dummy_input_ids])
inputs[1].set_data([dummy_attention_mask])
inputs[2].set_data([dummy_token_type_ids])

# 推理
outputs = model.predict(inputs)
print(f"输出向量: {outputs[0].get_data().shape}")
```

---

## 第五步: 部署到HarmonyOS项目

### 5.1 复制模型文件

```bash
# 复制.ms模型到rawfile目录
cp text_embedding.ms \
   "D:/jiangweipeng/Harmony/FileAnalyzer_HOS/entry/src/main/resources/rawfile/text_embedding.ms"
```

### 5.2 在ArkTS中加载模型

已有的 `MindSporeEmbeddingService.ets` 代码:

```typescript
// entry/src/main/ets/semantic/EmbeddingService.ets
import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { common } from '@kit.AbilityKit';

export class MindSporeEmbeddingService {
  private model: mindSporeLite.Model | null = null;
  private context: mindSporeLite.Context | null = null;
  private initialized: boolean = false;

  async initialize(appContext: common.Context, modelName: string = 'text_embedding.ms'): Promise<boolean> {
    try {
      // 创建MindSpore Lite上下文
      this.context = new mindSporeLite.Context();
      
      // 配置NPU优先 (如果可用)
      this.context.target = ['cpu', 'npu'];
      
      // 加载模型
      const modelPath = `${appContext.resourceDir}/${modelName}`;
      this.model = await mindSporeLite.Model.buildModelFromFile(modelPath, this.context);
      
      this.initialized = true;
      console.info('MindSpore Lite模型加载成功');
      return true;
    } catch (error) {
      console.error(`模型加载失败: ${error}`);
      return false;
    }
  }

  async encode(text: string): Promise<number[] | null> {
    if (!this.initialized || !this.model) {
      console.error('模型未初始化');
      return null;
    }

    try {
      // Tokenize文本 (需要实现tokenizer)
      const tokens = this.tokenize(text);
      
      // 创建输入tensor
      const inputs = this.model.createInputs();
      inputs[0].setData(tokens.inputIds);
      inputs[1].setData(tokens.attentionMask);
      inputs[2].setData(tokens.tokenTypeIds);
      
      // 推理
      const outputs = await this.model.predict(inputs);
      
      // 提取向量
      const embedding = outputs[0].getData();
      return Array.from(embedding);
    } catch (error) {
      console.error(`编码失败: ${error}`);
      return null;
    }
  }

  private tokenize(text: string): { inputIds: Int32Array, attentionMask: Int32Array, tokenTypeIds: Int32Array } {
    // 实现简单的tokenizer
    // 或者加载vocab.txt进行分词
    // ...
  }
}
```

---

## 第六步: 实现Tokenizer (ArkTS)

### 6.1 创建BertTokenizer

创建文件 `entry/src/main/ets/utils/BertTokenizer.ets`:

```typescript
// BertTokenizer.ets - BERT分词器
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

export class BertTokenizer {
  private vocab: Map<string, number> = new Map();
  private unkTokenId: number = 100; // [UNK]
  private maxLength: number = 128;

  async loadVocab(context: common.Context, vocabPath: string = 'vocab.txt'): Promise<void> {
    try {
      // 读取词表文件
      const file = await fileIo.open(`${context.resourceDir}/${vocabPath}`, fileIo.OpenMode.READ_ONLY);
      const content = await fileIo.readText(file.fd);
      await fileIo.close(file.fd);

      // 解析词表
      const lines = content.split('\n');
      for (let i = 0; i < lines.length; i++) {
        const token = lines[i].trim();
        if (token) {
          this.vocab.set(token, i);
        }
      }
      
      console.info(`词表加载完成: ${this.vocab.size} 词`);
    } catch (error) {
      console.error(`词表加载失败: ${error}`);
    }
  }

  tokenize(text: string): number[] {
    // 基本分词 - 字符级
    const tokens: string[] = [];
    
    // 添加[CLS]
    tokens.push('[CLS]');
    
    // 分词 (简化版: 字符分割)
    const chars = text.split('');
    for (const char of chars) {
      if (this.vocab.has(char)) {
        tokens.push(char);
      } else {
        tokens.push('[UNK]');
      }
    }
    
    // 添加[SEP]
    tokens.push('[SEP]');
    
    // 截断
    if (tokens.length > this.maxLength) {
      tokens.splice(this.maxLength - 1, tokens.length - this.maxLength);
      tokens.push('[SEP]');
    }
    
    // 转为ID
    return tokens.map(t => this.vocab.get(t) ?? this.unkTokenId);
  }

  encode(text: string): { inputIds: Int32Array, attentionMask: Int32Array, tokenTypeIds: Int32Array } {
    const ids = this.tokenize(text);
    const length = ids.length;

    // padding
    const inputIds = new Int32Array(this.maxLength);
    const attentionMask = new Int32Array(this.maxLength);
    const tokenTypeIds = new Int32Array(this.maxLength);

    for (let i = 0; i < this.maxLength; i++) {
      if (i < length) {
        inputIds[i] = ids[i];
        attentionMask[i] = 1;
        tokenTypeIds[i] = 0;
      } else {
        inputIds[i] = 0; // [PAD]
        attentionMask[i] = 0;
        tokenTypeIds[i] = 0;
      }
    }

    return { inputIds, attentionMask, tokenTypeIds };
  }
}
```

---

## 完整转换流程检查清单

| 步骤 | 操作 | 文件 | 状态 |
|------|------|------|------|
| 1 | 安装Python环境 | - | [ ] |
| 2 | 导出ONNX模型 | `export_to_onnx.py` → `text_embedding.onnx` | [ ] |
| 3 | 验证ONNX模型 | 测试输出维度384 | [ ] |
| 4 | 下载MindSpore Lite Converter | `converter_lite.exe` | [ ] |
| 5 | ONNX转.ms | `text_embedding.ms` | [ ] |
| 6 | 复制.ms到rawfile | `entry/src/main/resources/rawfile/text_embedding.ms` | [ ] |
| 7 | 复制vocab.txt | `entry/src/main/resources/rawfile/vocab.txt` | [ ] |
| 8 | 验证HarmonyOS加载 | 真机测试 | [ ] |

---

## 替代方案: 使用预转换模型

如果转换过程复杂，可以考虑:

### 方案A: 使用华为云模型服务
- [HMS Retrieval API](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/data-retrieval-V5)
- 直接调用云端embedding服务

### 方案B: 使用开源.ms模型
MindSpore官方可能提供预转换的模型:
- [MindSpore Model Zoo](https://gitee.com/mindspore/models)

### 方案C: 使用更小的模型
考虑转换为更轻量的模型:
- `paraphrase-MiniLM-L3-v2` (3层，更快)
- `all-MiniLM-L6-v2` (6层，平衡)

---

## 注意事项

1. **模型大小:** 原模型约400MB，转换为.ms后可能更小
2. **推理速度:** 手机端建议使用FP16量化
3. **序列长度:** 手机端建议max_length=64或128
4. **内存占用:** 注意MindSpore Lite的内存限制
5. **兼容性:** 验证ONNX算子是否被MindSpore Lite支持

---

## 参考文档

- [MindSpore Lite Converter Tool](https://www.mindspore.cn/lite/docs/zh-CN/master/use/converter_tool.html)
- [HarmonyOS MindSpore Lite Kit](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/mindspore-lite-overview-V5)
- [Sentence-Transformers文档](https://www.sbert.net/)
- [ONNX导出指南](https://pytorch.org/docs/stable/onnx.html)

---

## 附录: 快速执行命令汇总

```bash
# === Python环境准备 ===
conda create -n model_convert python=3.10
conda activate model_convert
pip install torch onnx onnxruntime transformers sentence-transformers

# === 导出ONNX ===
cd D:\jiangweipeng\Harmony\FileAnalyzer_HOS
python export_to_onnx.py

# === ONNX转.ms (Windows) ===
# 下载converter_lite后执行:
converter_lite.exe --fmk=ONNX --modelFile=text_embedding.onnx --outputFile=text_embedding

# === 部署到HarmonyOS ===
cp text_embedding.ms entry/src/main/resources/rawfile/
cp vocab.txt entry/src/main/resources/rawfile/
```