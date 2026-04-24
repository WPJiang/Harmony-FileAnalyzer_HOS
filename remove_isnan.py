#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
移除ONNX模型中的IsNaN节点，替换为常量False
解决MindSpore Lite Converter不支持IsNaN的问题
"""

import onnx
from onnx import numpy_helper
import numpy as np
import sys

def remove_isnan_nodes(model_path: str, output_path: str):
    """
    移除IsNaN节点，替换为常量False
    """
    print(f"加载模型: {model_path}")
    model = onnx.load(model_path)
    graph = model.graph

    # 创建常量False tensor
    false_tensor = numpy_helper.from_array(np.array(False, dtype=np.bool_), name="isnan_replacement_false")

    # 添加常量到graph
    false_const = onnx.helper.make_node(
        'Constant',
        inputs=[],
        outputs=['isnan_false_const'],
        value=false_tensor
    )

    # 找到所有IsNaN节点
    isnan_nodes = [node for node in graph.node if node.op_type == 'IsNaN']
    print(f"找到 {len(isnan_nodes)} 个IsNaN节点")

    if not isnan_nodes:
        print("没有IsNaN节点需要移除")
        onnx.save(model, output_path)
        return

    # 记录所有IsNaN的输出名
    isnan_outputs = {}
    for node in isnan_nodes:
        for output in node.output:
            isnan_outputs[output] = 'isnan_false_const'

    # 移除IsNaN节点
    for node in isnan_nodes:
        graph.node.remove(node)

    # 添加False常量节点
    graph.node.insert(0, false_const)

    # 更新所有使用IsNaN输出的节点
    for node in graph.node:
        for i, inp in enumerate(node.input):
            if inp in isnan_outputs:
                node.input[i] = isnan_outputs[inp]

    # 验证模型
    print("验证模型...")
    onnx.checker.check_model(model)

    # 保存模型
    print(f"保存模型: {output_path}")
    onnx.save(model, output_path)

    # 统计
    print(f"已移除 {len(isnan_nodes)} 个IsNaN节点")
    print(f"模型大小: {output_path}")

if __name__ == "__main__":
    input_file = sys.argv[1] if len(sys.argv) > 1 else "text_embedding.onnx"
    output_file = sys.argv[2] if len(sys.argv) > 2 else "text_embedding_no_isnan.onnx"
    remove_isnan_nodes(input_file, output_file)