#!/bin/bash
# 创建/复用自签名代码签名证书，保证多次重建后签名身份稳定（辅助功能授权不失效）。
set -e

CERT_CN="SuperRightClick Dev"
KEYCHAIN_NAME="superrightclick-dev.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME"
KEYCHAIN_PW="superrightclick-dev"

# 1) 确保专用钥匙串存在并解锁
if [ ! -f "$KEYCHAIN_PATH" ]; then
    security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN_PATH" >/dev/null
fi
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH" >/dev/null 2>&1 || true

# 2) 证书不存在则创建
if ! security find-identity -p codesigning "$KEYCHAIN_PATH" 2>/dev/null | grep -q "$CERT_CN"; then
    TMP="$(mktemp -d)"
    openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
        -days 3650 -nodes -subj "/CN=$CERT_CN/O=SuperRightClick/C=CN" \
        -addext "extendedKeyUsage=codeSigning" -addext "keyUsage=digitalSignature" >/dev/null 2>&1
    openssl pkcs12 -export -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -passout pass:"$KEYCHAIN_PW" >/dev/null 2>&1
    security import "$TMP/cert.p12" -k "$KEYCHAIN_PATH" -P "$KEYCHAIN_PW" -A -T /usr/bin/codesign >/dev/null
    security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN_PATH" "$TMP/cert.pem" >/dev/null
    rm -rf "$TMP"
    echo "已创建自签名证书: $CERT_CN"
fi

# 3) 输出身份名
IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN_PATH" 2>/dev/null | grep -o "\"$CERT_CN\"" | head -1 | tr -d '"')"
if [ -z "$IDENTITY" ]; then
    echo "错误：未找到代码签名身份" >&2
    exit 1
fi
echo "$IDENTITY"
