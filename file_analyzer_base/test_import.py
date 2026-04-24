"""
简单的 import 测试脚本
"""
import sys
print("=" * 60)
print("Python:", sys.version)
print("=" * 60)

modules = [
    ('torch', 'PyTorch'),
    ('transformers', 'Transformers'),
    ('sentence_transformers', 'Sentence Transformers'),
    ('sklearn', 'Scikit-learn'),
    ('PyQt5.QtWidgets', 'PyQt5'),
]

print("\n测试导入各模块...")
success = 0
fail = 0
for module, name in modules:
    try:
        mod = __import__(module)
        version = getattr(mod, '__version__', 'N/A')
        print(f'  [OK] {name}: {version}')
        success += 1
    except Exception as e:
        print(f'  [FAIL] {name}: {e}')
        fail += 1

print(f"\n结果: 成功 {success}, 失败 {fail}")

if fail == 0:
    print("\n测试 torch 功能...")
    import torch
    print(f'  torch.__version__: {torch.__version__}')
    x = torch.randn(3, 3)
    print(f'  创建张量成功: shape={x.shape}')
    print("\n所有测试通过!")
else:
    print("\n部分模块导入失败!")

input("\n按回车键退出...")