#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

swift build -c release
BIN_PATH=$(swift build -c release --show-bin-path)
cp "$BIN_PATH/picpicker" ./picpicker
chmod +x ./picpicker

echo "已生成 ./picpicker"

INSTALL_DIR="${PICPICKER_INSTALL_DIR:-$HOME/.local/bin}"
if [ -d "$INSTALL_DIR" ]; then
  # 写入临时文件再 mv 覆盖：避免复用旧 inode 导致 macOS 拒绝执行（SIGKILL/137）
  TEMP_TARGET="$INSTALL_DIR/.picpicker-new.$$"
  cp ./picpicker "$TEMP_TARGET"
  chmod +x "$TEMP_TARGET"
  mv -f "$TEMP_TARGET" "$INSTALL_DIR/picpicker"
  echo "已安装到 $INSTALL_DIR/picpicker，可直接输入 picpicker 启动"
else
  echo "未找到 $INSTALL_DIR，跳过 PATH 安装（可用 PICPICKER_INSTALL_DIR 指定目录）"
fi
