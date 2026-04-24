#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
将sentence-transformers模型导出为ONNX格式
用于后续转换为MindSpore Lite .ms格式

Usage:
    python export_to_onnx.py --model_path <path> --output <output.onnx> --max_length 128
"""

import torch
import onnx
import argparse
import os
import sys

try:
    from sentence_transformers import SentenceTransformer
except ImportError:
    print("请安装sentence-transformers: pip install sentence-transformers")
    sys.exit(1)

try:
    import onnxruntime as ort
except ImportError:
    print("请安装onnxruntime: pip install onnxruntime")
    sys.exit(1)


def export_sentence_transformer_to_onnx(
    model_path: str,
    output_path: str,
    max_seq_length: int = 128,
    opset_version: int = 12
):
    """
    导出sentence-transformers模型为ONNX格式

    Args:
        model_path: 原模型路径 (本地路径或HuggingFace模型名)
        output_path: ONNX输出路径
        max_seq_length: 最大序列长度 (手机端建议128或64)
        opset_version: ONNX算子版本 (建议12)
    """

    print(f"[1/5] 加载模型: {model_path}")

    # 加载模型
    if os.path.exists(model_path):
        model = SentenceTransformer(model_path)
    else:
        # 从HuggingFace下载
        print(f"本地路径不存在，尝试从HuggingFace下载: {model_path}")
        model = SentenceTransformer(model_path)

    # 获取模型组件
    print("[2/5] 分析模型结构...")
    print(f"  模型模块数: {len(model)}")

    # Transformer模块 (第一个模块)
    transformer_module = model[0]

    # 设置序列长度
    original_max_length = transformer_module.max_seq_length
    transformer_module.max_seq_length = max_seq_length
    print(f"  原始序列长度: {original_max_length}")
    print(f"  设置序列长度: {max_seq_length}")

    # 获取BERT模型
    bert_model = transformer_module.auto_model
    bert_model.eval()

    print(f"  BERT隐藏层维度: {bert_model.config.hidden_size}")
    print(f"  BERT层数: {bert_model.config.num_hidden_layers}")
    print(f"  词表大小: {bert_model.config.vocab_size}")

    # 创建dummy输入 - 使用int32类型与HarmonyOS MindSpore Lite兼容
    # 重要：torch.long是INT64，但MindSpore Lite Tensor.setData需要INT32
    print("[3/5] 创建测试输入...")
    dummy_input_ids = torch.zeros(1, max_seq_length, dtype=torch.int32)
    dummy_attention_mask = torch.ones(1, max_seq_length, dtype=torch.int32)
    dummy_token_type_ids = torch.zeros(1, max_seq_length, dtype=torch.int32)

    # 构建Mean Pooling模型
    class BertWithMeanPooling(torch.nn.Module):
        """
        BERT模型 + Mean Pooling
        直接输出sentence embedding
        """
        def __init__(self, bert):
            super().__init__()
            self.bert = bert

        def forward(self, input_ids, attention_mask, token_type_ids):
            # BERT输出
            outputs = self.bert(
                input_ids=input_ids,
                attention_mask=attention_mask,
                token_type_ids=token_type_ids,
                return_dict=True
            )

            # 获取token embeddings
            token_embeddings = outputs.last_hidden_state  # [batch, seq_len, hidden_size]

            # Mean Pooling
            # 扩展attention_mask维度
            input_mask_expanded = attention_mask.unsqueeze(-1).expand(token_embeddings.size()).float()

            # 加权求和
            sum_embeddings = torch.sum(token_embeddings * input_mask_expanded, dim=1)

            # 求和mask (避免除零)
            sum_mask = torch.clamp(input_mask_expanded.sum(dim=1), min=1e-9)

            # 平均
            embeddings = sum_embeddings / sum_mask

            return embeddings

    full_model = BertWithMeanPooling(bert_model)
    full_model.eval()

    # 测试推理
    print("[4/5] 测试模型推理...")
    with torch.no_grad():
        test_output = full_model(dummy_input_ids, dummy_attention_mask, dummy_token_type_ids)
    print(f"  测试输出维度: {test_output.shape}")
    print(f"  预期维度: (1, {bert_model.config.hidden_size})")

    if test_output.shape[1] != bert_model.config.hidden_size:
        print("  [警告] 输出维度与预期不符!")

    # 导出ONNX
    print(f"[5/5] 导出ONNX模型: {output_path}")

    # 使用传统导出方式，避免新版PyTorch的IsNaN算子
    torch.onnx.export(
        full_model,
        (dummy_input_ids, dummy_attention_mask, dummy_token_type_ids),
        output_path,
        input_names=['input_ids', 'attention_mask', 'token_type_ids'],
        output_names=['sentence_embedding'],
        dynamic_axes={
            'input_ids': {0: 'batch_size'},
            'attention_mask': {0: 'batch_size'},
            'token_type_ids': {0: 'batch_size'},
            'sentence_embedding': {0: 'batch_size'}
        },
        opset_version=opset_version,
        do_constant_folding=True,
        export_params=True,
        # 强制使用传统导出方式
        dynamo=False
    )

    # 验证ONNX模型
    print("验证ONNX模型...")
    onnx_model = onnx.load(output_path)
    onnx.checker.check_model(onnx_model)

    # 打印模型信息
    print("\nONNX模型信息:")
    print(f"  输入:")
    for input in onnx_model.graph.input:
        dims = [d.dim_value if d.dim_value else d.dim_param for d in input.type.tensor_type.shape.dim]
        print(f"    {input.name}: {dims}")
    print(f"  输出:")
    for output in onnx_model.graph.output:
        dims = [d.dim_value if d.dim_value else d.dim_param for d in output.type.tensor_type.shape.dim]
        print(f"    {output.name}: {dims}")

    # ONNX Runtime测试
    print("\nONNX Runtime推理测试...")
    session = ort.InferenceSession(output_path)

    ort_inputs = {
        'input_ids': dummy_input_ids.numpy(),
        'attention_mask': dummy_attention_mask.numpy(),
        'token_type_ids': dummy_token_type_ids.numpy()
    }

    ort_outputs = session.run(['sentence_embedding'], ort_inputs)

    print(f"  ONNX输出维度: {ort_outputs[0].shape}")
    print(f"  ONNX输出范围: [{ort_outputs[0].min():.4f}, {ort_outputs[0].max():.4f}]")

    # 对比PyTorch和ONNX输出
    max_diff = abs(test_output.numpy() - ort_outputs[0]).max()
    print(f"  PyTorch vs ONNX最大差异: {max_diff:.6f}")

    if max_diff < 1e-5:
        print("  ✓ ONNX转换成功，输出一致!")
    else:
        print("  [警告] PyTorch和ONNX输出有差异!")

    # 模型文件大小
    file_size = os.path.getsize(output_path) / (1024 * 1024)
    print(f"\n模型文件大小: {file_size:.2f} MB")

    print(f"\n========== 完成 ==========")
    print(f"ONNX模型已保存: {output_path}")
    print(f"下一步: 使用MindSpore Lite Converter转换为.ms格式")

    return output_path


def main():
    parser = argparse.ArgumentParser(description='导出sentence-transformers模型为ONNX格式')
    parser.add_argument('--model_path', type=str,
                        default='sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2',
                        help='模型路径 (本地或HuggingFace名称)')
    parser.add_argument('--output', type=str, default='minilm_l6_v2_int32.onnx',
                        help='ONNX输出文件名')
    parser.add_argument('--max_length', type=int, default=512,
                        help='最大序列长度 (HarmonyOS使用512)')
    parser.add_argument('--opset', type=int, default=12,
                        help='ONNX算子版本 (建议12)')

    args = parser.parse_args()

    export_sentence_transformer_to_onnx(
        model_path=args.model_path,
        output_path=args.output,
        max_seq_length=args.max_length,
        opset_version=args.opset
    )


if __name__ == "__main__":
    main()