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
# 启动一次再打 dmg（2026-09-15）：1.0.3、1.0.4 在 Xcode 里一切正常，装好却秒退——本地签名没有 Team ID，强化运行时的
# 「库验证」不让它加载内嵌的 Sparkle.framework（entitlements 里的 disable-library-validation 就是为这个）。
# Xcode 里跑的是开发者证书签的，测不出来，所以打好的 App 用 qa 档真启动一次，几秒内退出就不打包。
smoke_log="${work}/smoke.log"
"${app}/Contents/MacOS/Formora" -FormoraProfile qa > "${smoke_log}" 2>&1 &
smoke_pid=$!
sleep "${FORMORA_SMOKE_SECONDS:-6}"
if kill -0 "${smoke_pid}" 2>/dev/null; then
  kill "${smoke_pid}" 2>/dev/null || true
  wait "${smoke_pid}" 2>/dev/null || true
  echo "启动检查通过"
else
  smoke_status=0; wait "${smoke_pid}" || smoke_status=$?
  echo "打好的 App 启动后几秒内就退出了（退出码 ${smoke_status}），不打包。记录在 ${smoke_log}："
  head -5 "${smoke_log}"
  exit 1
fi
stage="${work}/dmg"
mkdir -p "${stage}"
ditto "${app}" "${stage}/Formora.app"
ln -s /Applications "${stage}/Applications"
dmg="${out_dir}/Formora-${version}.dmg"
[ -e "${dmg}" ] && dmg="${out_dir}/Formora-${version}-$(date +%Y%m%d-%H%M%S).dmg"
hdiutil create -volname "Formora ${version}" -srcfolder "${stage}" -format UDZO "${dmg}" > /dev/null
hdiutil verify "${dmg}" > /dev/null
echo "安装包：${dmg}"
