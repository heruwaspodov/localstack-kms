#!/bin/sh
set -eu

REGION="ap-southeast-1"
ALIAS="alias/msign-hash-signing"
PRIVATE_KEY="/keys/msign/private.pem"
WORKDIR="$(mktemp -d /tmp/kms-bootstrap.XXXXXX)"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT HUP INT TERM

if awslocal kms describe-key \
  --region "$REGION" \
  --key-id "$ALIAS" >/dev/null 2>&1; then
  echo "KMS alias already exists: $ALIAS"
  exit 0
fi

echo "Creating imported RSA signing key..."

KEY_ID="$(
  awslocal kms create-key \
    --region "$REGION" \
    --origin EXTERNAL \
    --key-usage SIGN_VERIFY \
    --key-spec RSA_2048 \
    --description "Local imported RSA signing key" \
    --query 'KeyMetadata.KeyId' \
    --output text
)"

awslocal kms get-parameters-for-import \
  --region "$REGION" \
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

openssl pkcs8 \
  -topk8 \
  -nocrypt \
  -in "$PRIVATE_KEY" \
  -outform DER \
  -out "$WORKDIR/plaintext-key.der"

openssl rand -out "$WORKDIR/aes-key.bin" 32

openssl enc -id-aes256-wrap-pad \
  -K "$(python3 -c 'import sys; print(open(sys.argv[1], "rb").read().hex())' "$WORKDIR/aes-key.bin")" \
  -iv A65959A6 \
  -in "$WORKDIR/plaintext-key.der" \
  -out "$WORKDIR/key-material-wrapped.bin"

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
  > "$WORKDIR/encrypted-key-material.bin"

awslocal kms import-key-material \
  --region "$REGION" \
  --key-id "$KEY_ID" \
  --encrypted-key-material "fileb://$WORKDIR/encrypted-key-material.bin" \
  --import-token "fileb://$WORKDIR/ImportToken.bin" \
  --expiration-model KEY_MATERIAL_DOES_NOT_EXPIRE

awslocal kms create-alias \
  --region "$REGION" \
  --alias-name "$ALIAS" \
  --target-key-id "$KEY_ID"

echo "KMS bootstrap completed."
echo "Alias: $ALIAS"
echo "Key ID: $KEY_ID"
