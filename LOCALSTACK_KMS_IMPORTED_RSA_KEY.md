# LocalStack KMS — Import Existing RSA Private Key for Local Hash Signing

Dokumentasi ini menjelaskan setup LocalStack KMS di macOS/Docker Desktop, mengimpor existing RSA private key, membuat alias KMS, dan membuktikan bahwa signature dari KMS dapat diverifikasi memakai certificate yang sudah ada.

> **Scope:** local development / integration test.  
> **Bukan:** pengganti AWS KMS, AWS CloudHSM, atau HSM production.

---

## Hasil akhir

Setelah seluruh langkah selesai, LocalStack memiliki KMS key berikut:

```text
KeySpec:  RSA_2048
KeyUsage: SIGN_VERIFY
Origin:   EXTERNAL
KeyState: Enabled
Alias:    alias/msign-hash-signing
```

Alur yang tervalidasi:

```text
private.pem
  → diimport ke LocalStack KMS
  → KMS Sign memakai SHA-256 + RSASSA_PKCS1_V1_5_SHA_256
  → signature diverifikasi memakai public key dari signing.crt
  → Signature Verified Successfully
```

---

## 1. Prasyarat

- macOS dengan Docker Desktop berjalan.
- Terminal / zsh.
- Folder berisi material key dan certificate:
  - `private.pem`
  - `signing.crt`
  - optional chain: `root-ca.crt`, `sub-ca.crt`
- OpenSSL tersedia pada host macOS.
- Jangan gunakan private key production yang sebenarnya untuk eksperimen LocalStack.

Cek Docker:

```bash
docker --version
docker compose version
```

---

## 2. Struktur folder

Buat project folder:

```bash
mkdir -p ~/AnotherWorks/localstack-kms/keys/msign
mkdir -p ~/AnotherWorks/localstack-kms/volume
cd ~/AnotherWorks/localstack-kms
```

Struktur yang diharapkan:

```text
localstack-kms/
├── compose.yaml
├── import-rsa-key.sh
├── .gitignore
├── .localstack-kms-key-id         # dibuat setelah CreateKey
├── keys/                          # JANGAN commit
│   └── msign/
│       ├── private.pem
│       ├── signing.crt
│       ├── root-ca.crt
│       └── sub-ca.crt
└── volume/                        # state LocalStack, JANGAN commit
```

Salin key dan certificate ke folder `keys/msign/`.

---

## 3. Lindungi key dari Git

Buat `.gitignore`:

```gitignore
# Sensitive key material and local LocalStack state
keys/
volume/
.localstack-kms-key-id
.env
```

Jangan commit atau upload:

- `private.pem`
- file hasil konversi `.der`, `.p8`, atau `.key`
- folder `volume/`, karena LocalStack dapat menyimpan state/key material impor di sana
- output log yang memuat data sensitif

---

## 4. Docker Compose untuk LocalStack KMS

> Gunakan tag **`4.14.0`**, bukan `latest`.  
> Pada environment ini, image `latest` meminta `LOCALSTACK_AUTH_TOKEN` dan berhenti dengan exit code 55. Tag Community `4.14.0` dapat dipakai untuk local test tanpa auth token.

Buat `compose.yaml`:

```yaml
services:
  localstack:
    container_name: localstack-kms
    image: localstack/localstack:4.14.0

    ports:
      - "127.0.0.1:4566:4566"

    environment:
      SERVICES: kms
      AWS_DEFAULT_REGION: ap-southeast-1
      DEBUG: "1"
      PERSISTENCE: "1"

    volumes:
      # Ganti path host berikut sesuai lokasi folder project di Mac.
      - "${HOME}/AnotherWorks/localstack-kms/volume:/var/lib/localstack"
      - "${HOME}/AnotherWorks/localstack-kms/keys:/keys:ro"
```

Catatan:

- Port `4566` adalah endpoint AWS API LocalStack.
- `:ro` membuat folder key hanya bisa dibaca dari container.
- Untuk repository yang lokasinya berbeda, ganti `/AnotherWorks/localstack-kms` sesuai path lokal masing-masing developer.
- `PERSISTENCE=1` membuat state LocalStack bertahan di folder `volume/`.

---

## 5. Jalankan LocalStack

```bash
cd ~/AnotherWorks/localstack-kms

docker compose down
docker compose up -d
docker compose logs -f localstack
```

Tanda startup berhasil:

```text
Ready.
```

Keluar dari stream log dengan `Ctrl + C`. Ini hanya menghentikan tampilan log, bukan containernya.

Cek status:

```bash
docker compose ps
```

Cek health endpoint:

```bash
curl -s http://localhost:4566/_localstack/health
```

Expected minimal:

```json
{
  "services": {
    "kms": "running"
  },
  "edition": "community",
  "version": "4.14.0"
}
```

> Membuka `http://localhost:4566` dari browser dapat terlihat kosong/putih. Itu normal karena endpoint tersebut adalah AWS API endpoint, bukan dashboard UI. Gunakan `/_localstack/health` untuk health check.

---

## 6. Pastikan file key sudah di-mount ke container

```bash
docker compose exec localstack sh -lc 'ls -lah /keys && ls -lah /keys/msign'
```

Expected contoh output:

```text
/keys/msign/private.pem
/keys/msign/signing.crt
/keys/msign/root-ca.crt
/keys/msign/sub-ca.crt
```

Jika `/keys/msign` tidak ditemukan, cek mount:

```bash
docker inspect localstack-kms \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
```

Pastikan ada mapping host folder `keys` ke `/keys`, lalu recreate:

```bash
docker compose down
docker compose up -d --force-recreate
```

---

## 7. Verifikasi private key dan certificate adalah pasangan yang sama

### 7.1 Cek tipe dan ukuran private key

```bash
openssl pkey -in keys/msign/private.pem -noout -text | head -n 1
```

Target untuk contoh ini:

```text
RSA Private-Key: (2048 bit)
```

### 7.2 Bandingkan public key hash

```bash
echo "Private key public-key hash:"
openssl pkey -in keys/msign/private.pem -pubout -outform DER | shasum -a 256

echo "Certificate public-key hash:"
openssl x509 -in keys/msign/signing.crt -pubkey -noout \
  | openssl pkey -pubin -pubout -outform DER \
  | shasum -a 256
```

Kedua SHA-256 hash **harus identik**.

Jika hash berbeda, hentikan proses. `private.pem` dan `signing.crt` bukan key pair yang sama.

---

## 8. Buat KMS key kosong dengan origin EXTERNAL

Untuk RSA private key 2048-bit:

```bash
KEY_ID=$(
  docker compose exec -T localstack awslocal kms create-key \
    --origin EXTERNAL \
    --key-usage SIGN_VERIFY \
    --key-spec RSA_2048 \
    --description "Local test imported RSA signing key" \
    --query 'KeyMetadata.KeyId' \
    --output text
)

echo "$KEY_ID" | tee .localstack-kms-key-id

docker compose exec -T localstack awslocal kms describe-key \
  --key-id "$KEY_ID" \
  --query 'KeyMetadata.{KeyId:KeyId,KeyState:KeyState,Origin:Origin,KeyUsage:KeyUsage,KeySpec:KeySpec}' \
  --output table
```

Expected status sebelum import:

```text
KeyState: PendingImport
Origin:   EXTERNAL
KeyUsage: SIGN_VERIFY
KeySpec:  RSA_2048
```

---

## 9. Ambil parameter import (optional verification)

```bash
KEY_ID="$(cat .localstack-kms-key-id)"

docker compose exec -T localstack \
  awslocal kms get-parameters-for-import \
  --key-id "$KEY_ID" \
  --wrapping-algorithm RSA_AES_KEY_WRAP_SHA_256 \
  --wrapping-key-spec RSA_4096 \
  --query '{KeyId:KeyId,ParametersValidTo:ParametersValidTo}' \
  --output table
```

Import RSA private key menggunakan hybrid wrapping:

```text
private.pem
  → PKCS#8 DER
  → AES-256 Key Wrap with Padding
  → AES key dienkripsi RSA-OAEP SHA-256 memakai wrapping public key
  → ImportKeyMaterial
```

---

## 10. Import RSA private key ke LocalStack KMS

Buat `import-rsa-key.sh`:

```bash
cat > import-rsa-key.sh <<'BASH'
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
BASH

chmod +x import-rsa-key.sh
./import-rsa-key.sh
```

Expected final state:

```text
KeyState: Enabled
Origin:   EXTERNAL
KeyUsage: SIGN_VERIFY
KeySpec:  RSA_2048
```

### Catatan troubleshooting: `xxd: not found`

Jangan gunakan:

```bash
xxd -p < "$WORKDIR/aes-key.bin"
```

Image LocalStack ini tidak menyediakan `xxd`. Script di atas memakai Python untuk mengubah AES key menjadi hex:

```bash
python3 -c 'import sys; print(open(sys.argv[1], "rb").read().hex())'
```

Jika `xxd` gagal, OpenSSL dapat menggunakan AES key yang salah dan `ImportKeyMaterial` akan gagal.

---

## 11. Buat alias KMS

Alias menghindari hardcode UUID KeyId di aplikasi:

```bash
KEY_ID="$(cat .localstack-kms-key-id)"

docker compose exec -T localstack awslocal kms create-alias \
  --alias-name alias/msign-hash-signing \
  --target-key-id "$KEY_ID"

docker compose exec -T localstack awslocal kms describe-key \
  --key-id alias/msign-hash-signing \
  --query 'KeyMetadata.{KeyId:KeyId,KeyState:KeyState,KeySpec:KeySpec,KeyUsage:KeyUsage}' \
  --output table
```

Gunakan di aplikasi:

```text
alias/msign-hash-signing
```

---

## 12. Smoke test: sign dari KMS dan verify memakai signing certificate

Command ini:

1. Membuat message dummy.
2. Membuat SHA-256 digest.
3. Meminta LocalStack KMS melakukan signing.
4. Mengambil public key dari `signing.crt`.
5. Memverifikasi signature.

```bash
KEY_ID="$(cat .localstack-kms-key-id)"

docker compose exec -T localstack sh -s "$KEY_ID" <<'SH'
set -eu

KEY_ID="$1"
WORKDIR="$(mktemp -d /tmp/kms-sign-test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

printf 'localstack kms signing smoke test\n' > "$WORKDIR/message.txt"

openssl dgst -sha256 -binary \
  "$WORKDIR/message.txt" \
  > "$WORKDIR/digest.bin"

awslocal kms sign \
  --key-id "$KEY_ID" \
  --message "fileb://$WORKDIR/digest.bin" \
  --message-type DIGEST \
  --signing-algorithm RSASSA_PKCS1_V1_5_SHA_256 \
  --query Signature \
  --output text \
| python3 -c '
import base64, sys
open(sys.argv[1], "wb").write(base64.b64decode(sys.stdin.read()))
' "$WORKDIR/signature.bin"

openssl x509 \
  -in /keys/msign/signing.crt \
  -pubkey -noout \
  > "$WORKDIR/public.pem"

openssl pkeyutl -verify \
  -pubin \
  -inkey "$WORKDIR/public.pem" \
  -in "$WORKDIR/digest.bin" \
  -sigfile "$WORKDIR/signature.bin" \
  -pkeyopt rsa_padding_mode:pkcs1 \
  -pkeyopt digest:sha256
SH
```

Expected output:

```text
Signature Verified Successfully
```

Jika output tersebut muncul, KMS key yang diimport dan `signing.crt` terbukti cocok secara kriptografis.

---

## 13. Environment untuk hash-signing service

### Service berjalan langsung di Mac

```env
AWS_REGION=ap-southeast-1
AWS_KMS_KEY_ID=alias/msign-hash-signing
AWS_ENDPOINT_URL=http://localhost:4566
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
```

### Service berjalan sebagai container di Docker Compose yang sama

```env
AWS_REGION=ap-southeast-1
AWS_KMS_KEY_ID=alias/msign-hash-signing
AWS_ENDPOINT_URL=http://localstack:4566
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
```

Perbedaan endpoint:

```text
Host macOS                  → http://localhost:4566
Container satu Compose net  → http://localstack:4566
```

Aplikasi perlu menggunakan:

```text
MessageType:       DIGEST
SigningAlgorithm:  RSASSA_PKCS1_V1_5_SHA_256
```

sesuai alur hash-signing / PDF signing yang diuji.

---

## 14. Troubleshooting ringkas

### Container berhenti dengan exit code 55 / License activation failed

Penyebab umum: memakai `localstack/localstack:latest`, yang meminta `LOCALSTACK_AUTH_TOKEN`.

Solusi local test ini:

```yaml
image: localstack/localstack:4.14.0
```

Kemudian:

```bash
docker compose down
docker compose pull
docker compose up -d --force-recreate
```

### `No such container: localstack-kms`

Container belum dibuat/berjalan, atau sebelumnya sudah `docker compose down`.

```bash
docker compose up -d
docker compose ps
```

### `/keys/msign` tidak ada

Periksa mount dan pastikan path host dalam `compose.yaml` benar:

```bash
docker inspect localstack-kms \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
```

Kemudian recreate container.

### `ImportKeyMaterial` menghasilkan `InternalError`

Periksa bahwa script tidak menggunakan `xxd` yang tidak tersedia di image. Gunakan versi script pada dokumentasi ini yang mengonversi AES key ke hex melalui Python.

### Browser membuka `http://localhost:4566` tetapi putih/kosong

Normal. Itu endpoint AWS API. Gunakan:

```bash
curl -s http://localhost:4566/_localstack/health
```

---

## 15. Reset environment lokal

> Perintah berikut menghapus state LocalStack lokal, termasuk imported key yang tersimpan di `volume/`.

```bash
docker compose down
rm -rf volume/*
rm -f .localstack-kms-key-id
```

Setelah reset, ulangi dari langkah **8** untuk membuat dan mengimpor KMS key baru.

---

## 16. Security dan batasan penting

1. **LocalStack bukan HSM dan bukan AWS KMS production.**  
   Ia hanya dipakai untuk pengembangan serta verifikasi integrasi API.

2. **Imported private key dapat tersimpan pada folder `volume/`.**  
   Lindungi folder tersebut seperti private key biasa, jangan commit atau share.

3. **Jangan gunakan private key production/GlobalSign/CloudHSM production di LocalStack.**  
   Gunakan key staging atau test-only.

4. **Keberhasilan LocalStack tidak membuktikan kesetaraan penuh dengan AWS KMS.**  
   Validasi akhir tetap perlu dilakukan pada AWS KMS asli, termasuk permission IAM, region, import flow, signing API, dan output yang dipakai oleh PDF/CMS pipeline.

5. **Keberhasilan `Signature Verified Successfully` hanya membuktikan kecocokan kriptografis key dan certificate.**  
   Validitas trust Adobe / AATL / LTV / certificate chain merupakan concern terpisah yang harus diuji di pipeline PDF lengkap.

---

## Checklist akhir

```text
[ ] Docker Desktop running
[ ] LocalStack KMS health = running
[ ] /keys/msign/private.pem terlihat di container
[ ] private.pem dan signing.crt punya public-key hash yang sama
[ ] KMS key: RSA_2048 + SIGN_VERIFY + EXTERNAL
[ ] KMS key state = Enabled
[ ] Alias alias/msign-hash-signing tersedia
[ ] KMS Sign menghasilkan signature
[ ] Signature Verified Successfully terhadap signing.crt
[ ] keys/, volume/, .localstack-kms-key-id tidak masuk Git
```
