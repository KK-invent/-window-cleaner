#!/bin/bash
# 双击运行：自动打开测试窗口，验证“扫把”的各项关闭场景，结果保存在本目录的“验证报告”文件夹。
# 自检只操作 WC测试应用 打开的测试窗口，不会碰你自己的窗口。
# 需要先给“扫把”授予辅助功能（必需）和屏幕录制（建议）权限。
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/扫把.app"
[ -d "$APP" ] || APP="$DIR/dist/扫把.app"
if pgrep -f "扫把.app/Contents/MacOS/WindowCleaner" >/dev/null; then
  echo "扫把正在运行。请右键点击 Dock 里的“扫把”图标，选择“运行自检”。"
  echo "（或者先退出扫把，再双击本文件。）"
  exit 0
fi
open "$APP" --args --selftest --hosts-dir "$DIR/dist/测试工具" --report-dir "$DIR/验证报告"
echo "自检已启动，大约需要 1 分钟。期间请不要操作鼠标键盘。报告会保存在：$DIR/验证报告"
