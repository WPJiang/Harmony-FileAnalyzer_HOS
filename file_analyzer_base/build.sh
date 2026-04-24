#!/bin/bash
# 文件分析管理器 - 一键打包脚本
# 在 Git Bash 中运行

echo "============================================================"
echo "          文件分析管理器 - 一键打包脚本"
echo "============================================================"
echo ""

# 切换到脚本所在目录
cd "$(dirname "$0")"

PYTHON_EXE="C:/Users/Administrator/miniconda3/envs/file_analyzer/python.exe"
SPEC_FILE="文件分析管理器.spec"

echo "[1/4] 检查Python环境..."
if [ ! -f "$PYTHON_EXE" ]; then
    echo "[错误] Python不存在: $PYTHON_EXE"
    read -p "按回车键退出..."
    exit 1
fi
"$PYTHON_EXE" --version
echo ""

echo "[2/4] 清空旧的打包文件..."
if [ -d "build" ]; then
    rm -rf build
    echo "      已删除 build 目录"
fi
if [ -d "dist" ]; then
    rm -rf dist
    echo "      已删除 dist 目录"
fi
echo ""

echo "[3/4] 开始打包（请耐心等待）..."
echo ""
"$PYTHON_EXE" -m PyInstaller "$SPEC_FILE" --clean -y

if [ $? -ne 0 ]; then
    echo ""
    echo "[错误] 打包失败！"
    read -p "按回车键退出..."
    exit 1
fi

echo ""
echo "[4/4] 打包完成！"
echo ""
echo "============================================================"
echo "输出目录: $(pwd)/dist/文件分析管理器"
echo "可执行文件: 文件分析管理器.exe"
echo "============================================================"
echo ""

# 显示文件大小
if [ -f "dist/文件分析管理器/文件分析管理器.exe" ]; then
    EXE_SIZE=$(du -h "dist/文件分析管理器/文件分析管理器.exe" | cut -f1)
    TOTAL_SIZE=$(du -sh "dist/文件分析管理器" | cut -f1)
    echo "可执行文件大小: $EXE_SIZE"
    echo "总打包大小: $TOTAL_SIZE"
fi

echo ""
read -p "按回车键退出..."