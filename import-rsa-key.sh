#!/bin/sh
# LocalStack READY-stage bootstrap:
# creates an EXTERNAL asymmetric KMS key, imports the RSA private key,
# and exposes it through a stable alias.
#
# This script is intentionally idempotent. If the alias already resolves to
# an Enabled key, it exits without changing the existing key.

set -eu

REGION="${AWS_DEFAULT_REGION:-ap-southeast-1}"
ALIAS="${KMS_ALIAS:-alias/msign-hash-signing}"
PRIVATE_KEY_PATH="${PRIVATE_KEY_PATH:-/keys/msign/private.pem}"
DESCRIPTION="${KMS_DESCRIPTION:-Local imported RSA signing key}"

log() {
  printf '%s\n' "[kms-bootstrap] $*"
}

fail() {
  printf '%s\n' "[kms-bootstrap] ERROR: $*" >&2
  exit 1
}

[ -f "$PRIVATE_KEY_PATH" ] || fail "Private key not found: $PRIVATE_KEY_PATH"

# LocalStack executes this script only after its READY stage, so KMS should
# already be reachable. Still, fail clearly if an unexpected alias state exists.
if awslocal kms describe-key \
  --region "$REGION" \
  --key-id "$ALIAS" \
  --query 'KeyMetadata.KeyState' \
  --output text > /tmp/kms-bootstrap-existing-state 2>/dev/null; then
  EXISTING_STATE="$(cat /tmp/kms-bootstrap-existing-state)"
  rm -f /tmp/kms-bootstrap-existing-state

  if [ "$EXISTING_STATE" = "Enabled" ]; then
    log "Alias already exists and key is Enabled: $ALIAS"
    exit 0
  fi

  fail "Alias already exists but key state is '$EXISTING_STATE'; resolve it before bootstrapping again."
fi
rm -f /tmp/kms-bootstrap-existing-state

OPENSSL_VERSION="$(openssl version)"
printf '%s\n' "$OPENSSL_VERSION" | grep -Eq '^OpenSSL 3\.' || \
  fail "OpenSSL 3.x is required for AES key wrap. Found: $OPENSSL_VERSION"

# Supports the RSA KMS sizes accepted by the import flow.
KEY_BITS="$(
  openssl pkey -in "$PRIVATE_KEY_PATH" -noout -text 2>/dev/null \
    | sed -n 's/.*(\([0-9][0-9]*\) bit.*/\1/p' \
    | head -n 1
)"

case "$KEY_BITS" in
  2048|3072|4096)
    KEY_SPEC="RSA_${KEY_BITS}"
    ;;
  *)
    fail "Unsupported or unreadable RSA key size: '${KEY_BITS:-unknown}'. Expected 2048, 3072, or 4096."
    ;;
esac

WORKDIR="$(mktemp -d /tmp/kms-bootstrap.XXXXXX)"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT HUP INT TERM

log "Creating $KEY_SPEC KMS key with Origin=EXTERNAL"

KEY_ID="$(
  awslocal kms create-key \
    --region "$REGION" \
    --origin EXTERNAL \
    --key-usage SIGN_VERIFY \
    --key-spec "$KEY_SPEC" \
    --description "$DESCRIPTION" \
    --query 'KeyMetadata.KeyId' \
    --output text
)"

log "Requesting wrapping public key and import token"
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

with open(params_path, encoding="utf-8") as source:
    data = json.load(source)

with open(f"{workdir}/WrappingPublicKey.der", "wb") as target:
    target.write(base64.b64decode(data["PublicKey"]))

with open(f"{workdir}/ImportToken.bin", "wb") as target:
    target.write(base64.b64decode(data["ImportToken"]))
PY

log "Converting private key to PKCS#8 DER"
openssl pkcs8 \
  -topk8 \
  -nocrypt \
  -in "$PRIVATE_KEY_PATH" \
  -outform DER \
  -out "$WORKDIR/PlaintextKeyMaterial.der"

log "Generating temporary AES-256 wrapping key"
openssl rand -out "$WORKDIR/aes-key.bin" 32

AES_KEY_HEX="$(
  python3 -c 'import sys; print(open(sys.argv[1], "rb").read().hex())' \
    "$WORKDIR/aes-key.bin"
)"

log "Wrapping PKCS#8 key material with AES Key Wrap with Padding"
openssl enc -id-aes256-wrap-pad \
  -K "$AES_KEY_HEX" \
  -iv A65959A6 \
  -in "$WORKDIR/PlaintextKeyMaterial.der" \
  -out "$WORKDIR/key-material-wrapped.bin"

log "Encrypting temporary AES key with RSA-OAEP SHA-256"
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

log "Importing private key material"
awslocal kms import-key-material \
  --region "$REGION" \
  --key-id "$KEY_ID" \
  --encrypted-key-material "fileb://$WORKDIR/EncryptedKeyMaterial.bin" \
  --import-token "fileb://$WORKDIR/ImportToken.bin" \
  --expiration-model KEY_MATERIAL_DOES_NOT_EXPIRE >/dev/null

log "Creating stable alias: $ALIAS"
awslocal kms create-alias \
  --region "$REGION" \
  --alias-name "$ALIAS" \
  --target-key-id "$KEY_ID"

log "Bootstrap complete"
awslocal kms describe-key \
  --region "$REGION" \
  --key-id "$ALIAS" \
  --query 'KeyMetadata.{KeyId:KeyId,KeyState:KeyState,Origin:Origin,KeyUsage:KeyUsage,KeySpec:KeySpec}' \
  --output table
