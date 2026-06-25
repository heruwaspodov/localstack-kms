#!/usr/bin/env bash
set -euo pipefail

KEY_ID="$(tr -d '\r\n' < .localstack-kms-key-id)"

docker compose exec -T localstack sh -s "$KEY_ID" <<'SH'
set -eu

KEY_ID="$1"
WORKDIR="$(mktemp -d /tmp/kms-import.XXXXXX)"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT HUP INT TERM

echo "==> OpenSSL version"
openssl version

# RSA_AES_KEY_WRAP_SHA_256 membutuhkan OpenSSL 3.x
openssl version | grep -Eq '^OpenSSL 3\.' || {
  echo "ERROR: OpenSSL 3.x diperlukan untuk AES key wrap."
  exit 2
}

echo "==> Download wrapping public key + import token"
awslocal kms get-parameters-for-import \
  --key-id "$KEY_ID" \
  --wrapping-algorithm RSA_AES_KEY_WRAP_SHA_256 \
  --wrapping-key-spec RSA_4096 \
  --output json > "$WORKDIR/params.json"

python3 - "$WORKDIR/params.json" "$WORKDIR" <<'PY'
import base64
import json
import sys

params_path, workdir = sys.argv[1], sys.argv[2]

with open(params_path) as f:
    data = json.load(f)

with open(f"{workdir}/WrappingPublicKey.der", "wb") as f:
    f.write(base64.b64decode(data["PublicKey"]))

with open(f"{workdir}/ImportToken.bin", "wb") as f:
    f.write(base64.b64decode(data["ImportToken"]))
PY

echo "==> Convert private key to PKCS#8 DER"
openssl pkcs8 \
  -topk8 \
  -nocrypt \
  -in /keys/msign/private.pem \
  -outform DER \
  -out "$WORKDIR/PlaintextKeyMaterial.der"

echo "==> Generate temporary AES-256 wrapping key"
openssl rand -out "$WORKDIR/aes-key.bin" 32

echo "==> Wrap private key using AES Key Wrap with Padding"
openssl enc -id-aes256-wrap-pad \
  -K "$(python3 -c 'import sys; print(open(sys.argv[1], "rb").read().hex())' "$WORKDIR/aes-key.bin")" \
  -iv A65959A6 \
  -in "$WORKDIR/PlaintextKeyMaterial.der" \
  -out "$WORKDIR/key-material-wrapped.bin"

echo "==> Encrypt AES key using RSA-OAEP SHA-256"
openssl pkeyutl \
  -encrypt \
  -in "$WORKDIR/aes-key.bin" \
  -out "$WORKDIR/aes-key-wrapped.bin" \
  -inkey "$WORKDIR/WrappingPublicKey.der" \
  -keyform DER \
  -pubin \
  -pkeyopt rsa_padding_mode:oaep \
  -pkeyopt rsa_oaep_md:sha256 \
  -pkeyopt rsa_mgf1_md:sha256

cat \
  "$WORKDIR/aes-key-wrapped.bin" \
  "$WORKDIR/key-material-wrapped.bin" \
  > "$WORKDIR/EncryptedKeyMaterial.bin"

echo "==> Import key material into LocalStack KMS"
awslocal kms import-key-material \
  --key-id "$KEY_ID" \
  --encrypted-key-material "fileb://$WORKDIR/EncryptedKeyMaterial.bin" \
  --import-token "fileb://$WORKDIR/ImportToken.bin" \
  --expiration-model KEY_MATERIAL_DOES_NOT_EXPIRE

echo
echo "==> Final KMS key state"
awslocal kms describe-key \
  --key-id "$KEY_ID" \
  --query 'KeyMetadata.{KeyId:KeyId,KeyState:KeyState,Origin:Origin,KeyUsage:KeyUsage,KeySpec:KeySpec}' \
  --output table
SH
