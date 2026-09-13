#!/bin/bash
# 把 Formora 打成 macOS 安装包：生成工程 → 归档官网版（ReleaseDeveloperID）→ 取出签好名的 App → 做一个拖进
# 「应用程序」的 dmg。用法：bash package.sh [输出目录，默认桌面]
# 签名照 project.yml：默认本地签名（ad-hoc），不需要开发者账号；设了自己的开发团队就用它的证书。
# 每次在 build/ 下新建一个文件夹，不删任何东西。
# 中文旁边的变量一律加花括号：bash 会把「或（的字节读成变量名的一部分。
set -euo pipefail
cd "$(dirname "$0")"
out_dir=${1:-"${HOME}/Desktop"}
version=$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' project.yml)
work="build/package-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${work}" "${out_dir}"
command -v xcodegen >/dev/null || { echo "缺 XcodeGen：brew install xcodegen"; exit 1; }
xcodegen generate --quiet
echo "归档（ReleaseDeveloperID）…"
if ! xcodebuild archive -scheme Formora -configuration ReleaseDeveloperID -destination 'generic/platform=macOS' \
    -archivePath "${work}/Formora.xcarchive" -allowProvisioningUpdates > "${work}/archive.log" 2>&1; then
  grep -E "error:" "${work}/archive.log" | head -5 || true
  echo "归档失败，完整记录在 ${work}/archive.log"
  exit 1
fi
app="${work}/Formora.xcarchive/Products/Applications/Formora.app"
codesign --verify --deep --strict "${app}"
stage="${work}/dmg"
mkdir -p "${stage}"
ditto "${app}" "${stage}/Formora.app"
ln -s /Applications "${stage}/Applications"
dmg="${out_dir}/Formora-${version}.dmg"
[ -e "${dmg}" ] && dmg="${out_dir}/Formora-${version}-$(date +%Y%m%d-%H%M%S).dmg"
hdiutil create -volname "Formora ${version}" -srcfolder "${stage}" -format UDZO "${dmg}" > /dev/null
hdiutil verify "${dmg}" > /dev/null
echo "安装包：${dmg}"
