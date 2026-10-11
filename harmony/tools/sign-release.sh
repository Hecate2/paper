#!/usr/bin/env bash
#
# 生成 HarmonyOS release 签名材料并签名 HAP。
#
# 背景：HarmonyOS 只接受 ECDSA 签名（SHA256withECDSA），
# 安卓 release.jks 是 RSA-4096，官方工具直接拒绝，无法复用。
# 首次运行自建一套CA 链 + ECC 应用密钥 + 证书 + profile，
# 之后重复运行只做签名。
#
# 用法：
#   bash harmony/tools/sign-release.sh                # 签默认路径的 release HAP
#   bash harmony/tools/sign-release.sh <unsigned.hap> # 指定待签名文件
#
set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARMONY_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
SIGN_DIR="$HARMONY_DIR/signing"
PROPS="$SIGN_DIR/signing.properties"
KEYSTORE="$SIGN_DIR/harmony-release.p12"

die() { printf '\033[31m错误\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }

# ---- 定位 SDK 与 JDK --------------------------------------------------------
SDK="${DEVECO_SDK_HOME:-${OHOS_BASE_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}}"
SIGN_TOOL="$SDK/default/openharmony/toolchains/lib/hap-sign-tool.jar"
[ -f "$SIGN_TOOL" ] || die "找不到签名工具：$SIGN_TOOL"

DEVECO_JAVA="/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java"
if [ -x "$DEVECO_JAVA" ]; then
  JAVA="$DEVECO_JAVA"
elif [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  JAVA="$JAVA_HOME/bin/java"
else
  die "找不到 java，请设置 JAVA_HOME"
fi

# 签名工具把失败信息打在 stdout，且部分错误不返回非零退出码，
# 所以额外检查输出里有没有 ERROR。
signtool() {
  local log rc
  log="$("$JAVA" -jar "$SIGN_TOOL" "$@" 2>&1)" || true
  printf '%s\n' "$log" | sed 's/^/    /' >&2
  if printf '%s' "$log" | grep -q '^ERROR'; then
    die "签名工具执行失败：$*"
  fi
  rc=0
  return $rc
}

# ---- 读取 bundleName 与 compatibleVersion -----------------------------------
read_json5_str() { # file key
  python3 - "$1" "$2" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'"%s"\s*:\s*"([^"]*)"' % re.escape(sys.argv[2]), text)
print(m.group(1) if m else "")
PY
}

BUNDLE_NAME="$(read_json5_str "$HARMONY_DIR/AppScope/app.json5" bundleName)"
[ -n "$BUNDLE_NAME" ] || die "读不到 bundleName"

COMPAT_RAW="$(read_json5_str "$HARMONY_DIR/build-profile.json5" compatibleSdkVersion)"
COMPAT_API="$(printf '%s' "$COMPAT_RAW" | sed -n 's/.*(\([0-9]\+\)).*/\1/p')"
COMPAT_API="${COMPAT_API:-13}"

# ---- 口令：首次生成并保存 ---------------------------------------------------
mkdir -p "$SIGN_DIR"
if [ ! -f "$PROPS" ]; then
  umask 077
  {
    echo "# 鸿蒙签名材料口令。勿提交（已在 .gitignore 中）。"
    echo "HARMWAY_STORE_PASSWORD=$(openssl rand -hex 16)"
  } > "$PROPS"
  info "已生成签名口令：$PROPS"
fi
# shellcheck disable=SC1090
. "$PROPS"
: "${HARMWAY_STORE_PASSWORD:?口令缺失}"
KP="$HARMWAY_STORE_PASSWORD"

SUBJECT_ROOT="C=CN,O=D7,OU=io.github.hecate2,CN=D7 HarmonyOS Root CA"
SUBJECT_APP_CA="C=CN,O=D7,OU=io.github.hecate2,CN=D7 Application Signature Service CA"
SUBJECT_PROFILE_CA="C=CN,O=D7,OU=io.github.hecate2,CN=D7 Profile Signature Service CA"

# ---- 首次运行：生成密钥与证书链 ---------------------------------------------
if [ ! -f "$KEYSTORE" ]; then
  info "生成签名材料（首次运行，只需一次）"

  # CA 密钥用 RSA-4096。应用签名密钥与 profile 签名密钥必须用 ECDSA，
  # 官方工具对这两处只接受 SHA256withECDSA / SHA384withECDSA。
  for alias in root-ca sub-app-ca sub-profile-ca; do
    signtool generate-keypair -keyAlias "$alias" -keyPwd "$KP" \
      -keyAlg RSA -keySize 4096 -keystoreFile "$KEYSTORE" -keystorePwd "$KP"
  done
  signtool generate-keypair -keyAlias app -keyPwd "$KP" \
    -keyAlg ECC -keySize NIST-P-256 -keystoreFile "$KEYSTORE" -keystorePwd "$KP"
  signtool generate-keypair -keyAlias profile -keyPwd "$KP" \
    -keyAlg ECC -keySize NIST-P-384 -keystoreFile "$KEYSTORE" -keystorePwd "$KP"

  signtool generate-ca -keyAlias root-ca -keyPwd "$KP" -keyAlg RSA -keySize 4096 \
    -subject "$SUBJECT_ROOT" -validity 7300 -signAlg SHA384withRSA \
    -keystoreFile "$KEYSTORE" -keystorePwd "$KP" -outFile "$SIGN_DIR/root-ca.cer"

  signtool generate-ca -keyAlias sub-app-ca -keyPwd "$KP" -keyAlg RSA -keySize 4096 \
    -issuer "$SUBJECT_ROOT" -issuerKeyAlias root-ca -issuerKeyPwd "$KP" \
    -subject "$SUBJECT_APP_CA" -validity 3650 -signAlg SHA384withRSA \
    -keystoreFile "$KEYSTORE" -keystorePwd "$KP" -outFile "$SIGN_DIR/sub-app-sign.cer"

  signtool generate-ca -keyAlias sub-profile-ca -keyPwd "$KP" -keyAlg RSA -keySize 4096 \
    -issuer "$SUBJECT_ROOT" -issuerKeyAlias root-ca -issuerKeyPwd "$KP" \
    -subject "$SUBJECT_PROFILE_CA" -validity 3650 -signAlg SHA384withRSA \
    -keystoreFile "$KEYSTORE" -keystorePwd "$KP" -outFile "$SIGN_DIR/sub-profile-sign.cer"

  signtool generate-app-cert -keyAlias app -keyPwd "$KP" \
    -issuer "$SUBJECT_APP_CA" -issuerKeyAlias sub-app-ca -issuerKeyPwd "$KP" \
    -subject "C=CN,O=D7,OU=io.github.hecate2,CN=D7 HarmonyOS Release" \
    -validity 7300 -signAlg SHA256withECDSA \
    -rootCaCertFile "$SIGN_DIR/root-ca.cer" -subCaCertFile "$SIGN_DIR/sub-app-sign.cer" \
    -keystoreFile "$KEYSTORE" -keystorePwd "$KP" -outForm certChain \
    -outFile "$SIGN_DIR/app-release.cer"

  signtool generate-profile-cert -keyAlias profile -keyPwd "$KP" \
    -issuer "$SUBJECT_PROFILE_CA" -issuerKeyAlias sub-profile-ca -issuerKeyPwd "$KP" \
    -subject "C=CN,O=D7,OU=io.github.hecate2,CN=D7 Provision Profile Release" \
    -validity 7300 -signAlg SHA384withECDSA \
    -rootCaCertFile "$SIGN_DIR/root-ca.cer" -subCaCertFile "$SIGN_DIR/sub-profile-sign.cer" \
    -keystoreFile "$KEYSTORE" -keystorePwd "$KP" -outForm certChain \
    -outFile "$SIGN_DIR/profile-release.cer"
fi

# ---- profile：把应用证书与bundleName 绑进签名文件 ---------------------------
PROFILE_JSON="$SIGN_DIR/profile.json"
PROFILE_P7B="$SIGN_DIR/profile.p7b"
if [ ! -f "$PROFILE_P7B" ]; then
  info "生成 profile，bundleName=${BUNDLE_NAME}"
  PROFILE_JSON="$PROFILE_JSON" APP_CERT="$SIGN_DIR/app-release.cer" \
  BUNDLE_NAME="$BUNDLE_NAME" python3 - <<'PY'
import json, os, time, uuid
now = int(time.time())
profile = {
    "version-name": "2.0.0",
    "version-code": 2,
    "app-distribution-type": "os_integration",
    "uuid": str(uuid.uuid4()),
    "validity": {"not-before": now - 3600, "not-after": now + 3650 * 24 * 3600},
    "type": "release",
    "bundle-info": {
        "developer-id": "io.github.hecate2",
        "distribution-certificate": open(os.environ["APP_CERT"]).read(),
        "bundle-name": os.environ["BUNDLE_NAME"],
        "apl": "normal",
        "app-feature": "hos_normal_app",
    },
    "acls": {"allowed-acls": [""]},
    "permissions": {"restricted-permissions": []},
    "issuer": "pki_internal",
}
with open(os.environ["PROFILE_JSON"], "w") as f:
    json.dump(profile, f, indent=2)
PY
  signtool sign-profile -mode localSign -keyAlias profile -keyPwd "$KP" \
    -profileCertFile "$SIGN_DIR/profile-release.cer" -inFile "$PROFILE_JSON" \
    -signAlg SHA384withECDSA -keystoreFile "$KEYSTORE" -keystorePwd "$KP" \
    -outFile "$PROFILE_P7B"
fi

# ---- 签名 HAP ---------------------------------------------------------------
UNSIGNED="${1:-$HARMONY_DIR/entry/build/default/outputs/default/entry-default-unsigned.hap}"
[ -f "$UNSIGNED" ] || die "找不到待签名 HAP：$UNSIGNED"
SIGNED="${UNSIGNED%-unsigned.hap}-signed.hap"

info "签名：$(basename "$UNSIGNED")"
signtool sign-app -mode localSign -keyAlias app -keyPwd "$KP" \
  -appCertFile "$SIGN_DIR/app-release.cer" -profileFile "$PROFILE_P7B" \
  -inFile "$UNSIGNED" -signAlg SHA256withECDSA \
  -keystoreFile "$KEYSTORE" -keystorePwd "$KP" \
  -outFile "$SIGNED" -compatibleVersion "$COMPAT_API" -signCode 1

# ---- 验证签名 ---------------------------------------------------------------
info "验证签名"
signtool verify-app -inFile "$SIGNED" \
  -outCertChain "$SIGN_DIR/verify-out-chain.cer" -outProfile "$SIGN_DIR/verify-out-profile.p7b"

SIZE=$(wc -c < "$SIGNED" | tr -d ' ')
printf '\n\033[32m完成\033[0m %s（%s 字节）\n' "$SIGNED" "$SIZE"