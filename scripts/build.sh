#!/bin/bash
# 构建“扫把”及其测试工具。只需要 Xcode 命令行工具（swiftc），不需要完整 Xcode。
#
#   scripts/build.sh            # 构建全部：dist/扫把.app、dist/测试工具/*.app、build/CoreChecks
#   scripts/build.sh app        # 只构建主应用
#   scripts/build.sh testhost   # 只构建测试宿主
#   scripts/build.sh checks     # 只构建并运行逻辑检查
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
FLAGS=(-swift-version 5 -target "$TARGET" -sdk "$SDK" -O -whole-module-optimization)
WHAT="${1:-all}"

mkdir -p "$BUILD" "$DIST"

# 写 Info.plist：$1=路径 $2=显示名 $3=可执行文件名 $4=bundle id $5=开发语言 $6=额外键（可选）
write_plist() {
cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundleDisplayName</key><string>$2</string>
  <key>CFBundleExecutable</key><string>$3</string>
  <key>CFBundleIdentifier</key><string>$4</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>$5</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  ${6:-}
</dict>
</plist>
PLIST
}

# ── 固定签名 ──────────────────────────────────────────────
# 用项目内 signing/ 里的本机专用证书签名，签名身份为“应用编号 + 证书指纹”，每次构建保持不变，
# 所以系统设置里的辅助功能/屏幕录制授权在更新后依然有效。
# 证书只存在项目自己的钥匙串文件里，不改动登录钥匙串、不加入钥匙串搜索列表、不改系统信任设置。
SIGN_DIR="$ROOT/signing"
SIGN_KC="$SIGN_DIR/windowcleaner.keychain-db"
SIGN_PW_FILE="$SIGN_DIR/keychain-password"
SIGN_NAME="WindowCleaner Local Signing"

ensure_signing_identity() {
  [ -f "$SIGN_KC" ] && [ -f "$SIGN_PW_FILE" ] && return 0
  echo "▶ 首次构建：生成本机专用签名证书（只放在 ${SIGN_DIR}）"
  mkdir -p "$SIGN_DIR" && chmod 700 "$SIGN_DIR"
  local tmp; tmp="$(mktemp -d)"
  local pw; pw="$(openssl rand -hex 24)"
  cat > "$tmp/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $SIGN_NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 3650 -config "$tmp/cert.cnf" >/dev/null 2>&1 &&
  openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout "pass:$pw" -name "$SIGN_NAME" >/dev/null 2>&1 &&
  security create-keychain -p "$pw" "$SIGN_KC" &&
  security set-keychain-settings "$SIGN_KC" &&
  security unlock-keychain -p "$pw" "$SIGN_KC" &&
  security import "$tmp/id.p12" -k "$SIGN_KC" -P "$pw" -T /usr/bin/codesign >/dev/null &&
  security set-key-partition-list -S apple-tool:,apple: -s -k "$pw" "$SIGN_KC" >/dev/null 2>&1
  local ok=$?
  rm -rf "$tmp"   # 私钥只保留在项目钥匙串里
  if [ $ok -ne 0 ]; then
    echo "  ⚠ 生成签名证书失败，将使用临时签名（更新后需重新授权）"
    rm -f "$SIGN_KC"
    return 1
  fi
  printf '%s' "$pw" > "$SIGN_PW_FILE" && chmod 600 "$SIGN_PW_FILE" "$SIGN_KC"
}

sign_app() {
  if ensure_signing_identity; then
    security unlock-keychain -p "$(cat "$SIGN_PW_FILE")" "$SIGN_KC" &&
    codesign --force --keychain "$SIGN_KC" --sign "$SIGN_NAME" --timestamp=none "$1" 2>&1 | grep -v "replacing existing signature" && return 0
    codesign --verify "$1" 2>/dev/null && return 0
    echo "  ⚠ 固定签名失败，改用临时签名（更新后需重新授权）"
  fi
  codesign --force --sign - --timestamp=none "$1"
}

build_testhost() {
  echo "▶ 编译测试宿主"
  swiftc "${FLAGS[@]}" -o "$BUILD/WCTestHost" Sources/WCTestHost/*.swift
  mkdir -p "$DIST/测试工具"
  for v in A B; do
    local app="$DIST/测试工具/WC测试应用$v.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$BUILD/WCTestHost" "$app/Contents/MacOS/WCTestHost"
    write_plist "$app/Contents/Info.plist" "WC测试应用$v" "WCTestHost" "local.windowcleaner.testhost.$(echo $v | tr AB ab)" "en" \
      "<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>"
    codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1
  done
  echo "  → $DIST/测试工具/"
}

build_icon() {
  if [ ! -f "$BUILD/SaobaIcon.icns" ] || [ ! -f "$ROOT/Assets/SaobaIcon.png" ] || [ scripts/make_icon.swift -nt "$BUILD/SaobaIcon.icns" ]; then
    echo "▶ 生成图标"
    swiftc "${FLAGS[@]}" -o "$BUILD/make_icon" scripts/make_icon.swift
    rm -rf "$BUILD/SaobaIcon.iconset"
    mkdir -p "$ROOT/Assets"
    "$BUILD/make_icon" "$BUILD/SaobaIcon.iconset" "$ROOT/Assets/SaobaIcon.png"
    iconutil -c icns "$BUILD/SaobaIcon.iconset" -o "$BUILD/SaobaIcon.icns"
  fi
}

build_app() {
  build_icon
  echo "▶ 编译主应用"
  swiftc "${FLAGS[@]}" -parse-as-library -o "$BUILD/WindowCleaner" \
    Sources/WindowCleanerCore/*.swift Sources/WindowCleaner/*.swift
  # 先在临时目录组装（目录名带 .noindex，聚焦搜索不会收录），签名后安装到“应用程序”
  local app="$BUILD/staging.noindex/扫把.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/zh-Hans.lproj"
  cp "$BUILD/WindowCleaner" "$app/Contents/MacOS/WindowCleaner"
  cp "$BUILD/SaobaIcon.icns" "$app/Contents/Resources/SaobaIcon.icns"
  echo '"CFBundleDisplayName" = "扫把";' > "$app/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
  write_plist "$app/Contents/Info.plist" "扫把" "WindowCleaner" "local.windowcleaner.app" "zh_CN" \
    "<key>CFBundleIconFile</key><string>SaobaIcon</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
  <key>NSHumanReadableCopyright</key><string>本地自用工具，不联网</string>
  <key>WCProjectDir</key><string>${ROOT}</string>
  <key>NSAppleEventsUsageDescription</key><string>用于读取 Chrome 等浏览器窗口里的标签页标题和网址，并在你点击时关闭对应的标签页。不读取网页内容，不上传、不保存。</string>"
  sign_app "$app"
  echo "  签名：$(codesign -dr - "$app" 2>&1 | tail -1)"
  install_app "$app"
}

# 安装到“应用程序”（可用 INSTALL_DIR 指定别处）；只保留一份，避免启动台/聚焦搜索里出现两个
install_app() {
  local app="$1"
  local dir="${INSTALL_DIR:-/Applications}"
  local dest="$dir/扫把.app"
  if [ -w "$dir" ]; then
    local legacy="$dir/窗口清理.app"
    local expected="local.windowcleaner.app"
    # 只迁移本项目的旧应用；保留外层目录身份，让已有 Dock 书签跟随改名。
    if [ ! -e "$dest" ] && [ -d "$legacy" ]; then
      local legacy_id; legacy_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy/Contents/Info.plist" 2>/dev/null || true)"
      if [ "$legacy_id" = "$expected" ]; then mv "$legacy" "$dest"; fi
    fi
    if [ -e "$dest" ]; then
      local dest_id; dest_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist" 2>/dev/null || true)"
      if [ "$dest_id" != "$expected" ]; then
        echo "  ⚠ $dest 是另一个应用，停止安装，不覆盖它。"
        return 1
      fi
    fi
    codesign --verify --strict "$app"
    mkdir -p "$dest"
    rm -rf "$dest/Contents"
    ditto "$app/Contents" "$dest/Contents"
    codesign --verify --strict "$dest"
    rm -rf "$app" "$DIST/扫把.app"
    echo "  → 已安装到 $dest"
  else
    rm -rf "$DIST/扫把.app"
    mv "$app" "$DIST/扫把.app"
    echo "  ⚠ 没有写入 $dir 的权限，应用保留在 $DIST/扫把.app"
  fi
}

build_checks() {
  echo "▶ 编译逻辑检查"
  swiftc "${FLAGS[@]}" -parse-as-library -o "$BUILD/CoreChecks" \
    Sources/WindowCleanerCore/*.swift Sources/CoreChecks/*.swift
  echo "▶ 运行逻辑检查"
  "$BUILD/CoreChecks"
}

case "$WHAT" in
  app) build_app ;;
  testhost) build_testhost ;;
  checks) build_checks ;;
  all) build_testhost; build_app; build_checks ;;
  *) echo "未知参数：$WHAT"; exit 2 ;;
esac
