# LocalStack KMS — Persistent Bootstrap for Imported RSA Signing Key

Dokumen ini menjelaskan setup LocalStack KMS pada macOS + Docker Desktop untuk local hash-signing test. Private key RSA yang sudah ada diimpor ke KMS sebagai asymmetric key `SIGN_VERIFY`, lalu selalu tersedia melalui alias stabil:

```text
alias/msign-hash-signing
```

> **Scope:** local development dan integration testing.  
> **Bukan:** pengganti AWS KMS, AWS CloudHSM, atau HSM production.

---

## 1. Prinsip persistence yang dipakai

Pada LocalStack Community `4.14.0`, jangan mengandalkan `PERSISTENCE=1` sebagai jaminan bahwa imported key akan tetap ada setelah container di-recreate.

Setup ini memakai **persistent bootstrap**, bukan persistent physical KMS key:

```text
LocalStack boot
  → READY-stage script berjalan
  → cek alias alias/msign-hash-signing
  → alias/key masih Enabled? selesai
  → state hilang? buat EXTERNAL key baru
  → import private.pem yang sama
  → buat alias yang sama
```

Konsekuensi:

- Alias selalu stabil: `alias/msign-hash-signing`.
- UUID Key ID dan ARN dapat berubah setelah recreate/state loss.
- Aplikasi wajib memakai alias, bukan UUID/ARN.
- Certificate tetap cocok selama `private.pem` yang diimpor adalah key yang sama.

---

## 2. Prasyarat

- macOS dengan Docker Desktop berjalan.
- Docker Compose.
- LocalStack Community `4.14.0`.
- Git submodule private yang menyediakan `keys/msign/private.pem`.
- `private.pem` adalah RSA 2048, 3072, atau 4096 bit.
- `signing.crt` adalah pasangan dari `private.pem`.
- Jangan gunakan private key production untuk LocalStack experiment.

Cek tool:

```bash
docker --version
docker compose version
```

---

## 3. Struktur repository

```text
localstack-kms/
├── compose.yaml
├── import-rsa-key.sh                  # READY-stage idempotent bootstrap
├── README.md
├── LOCALSTACK_KMS_IMPORTED_RSA_KEY.md
├── keys/                              # private Git submodule, never commit publicly
│   └── msign/
│       ├── private.pem
│       ├── signing.crt
│       ├── root-ca.crt
│       └── sub-ca.crt
└── volume/                            # local state/cache, never commit
```

Pastikan `.gitignore` memuat:

```gitignore
keys/
volume/
.env
*.der
*.p8
*.key
```

Jika folder `keys` adalah Git submodule private, jangan tambahkan pola `keys/` ke `.gitignore` pada repository utama apabila hal itu mengganggu tracking submodule. Yang penting: private key tidak pernah disalin ke repository publik atau dikomit sebagai file biasa.

---

## 4. Verifikasi private key dan certificate

### 4.1 Cek RSA key size

```bash
openssl pkey -in keys/msign/private.pem -noout -text | head -n 1
```

Contoh:

```text
RSA Private-Key: (2048 bit)
```

### 4.2 Verifikasi certificate adalah pasangan key yang sama

```bash
echo "Private key public-key hash:"
openssl pkey -in keys/msign/private.pem -pubout -outform DER | shasum -a 256

echo "Certificate public-key hash:"
openssl x509 -in keys/msign/signing.crt -pubkey -noout \
  | openssl pkey -pubin -pubout -outform DER \
  | shasum -a 256
```

Dua hash SHA-256 harus identik. Jika berbeda, hentikan proses: key dan certificate bukan pasangan yang sama.

---

## 5. Docker Compose

Gunakan `localstack/localstack:4.14.0`, bukan `latest`.

> Pada setup ini, image `latest` meminta auth token dan tidak dipakai untuk local Community test.

`compose.yaml`:

```yaml
services:
  localstack:
    container_name: localstack-kms
    image: localstack/localstack:4.14.0

    ports:
      # Terbuka hanya pada Mac host.
      - "127.0.0.1:4566:4566"

    environment:
      SERVICES: kms
      AWS_DEFAULT_REGION: ap-southeast-1
      DEBUG: "1"

    volumes:
      # Private material hanya bisa dibaca dari container.
      - "./keys:/keys:ro"

      # Script ini otomatis dieksekusi LocalStack ketika READY.
      - "./import-rsa-key.sh:/etc/localstack/init/ready.d/01-bootstrap-kms.sh:ro"

      # Optional local state/cache. Bootstrap tetap wajib ada.
      - "./volume:/var/lib/localstack"
```

Pastikan script dapat dieksekusi:

```bash
chmod +x import-rsa-key.sh
git update-index --chmod=+x import-rsa-key.sh
```

> Bila Docker Desktop gagal mem-mount path relatif pada mesin tertentu, ganti sumber volume dengan absolute path ke checkout repository. Contoh:
>
> ```yaml
> - "${HOME}/AnotherWorks/localstack-kms/keys:/keys:ro"
> - "${HOME}/AnotherWorks/localstack-kms/import-rsa-key.sh:/etc/localstack/init/ready.d/01-bootstrap-kms.sh:ro"
> ```

---

## 6. Cara kerja `import-rsa-key.sh`

File `import-rsa-key.sh` sekarang adalah bootstrap script yang dieksekusi LocalStack dari folder `ready.d`.

Script melakukan hal berikut:

1. Memeriksa apakah alias `alias/msign-hash-signing` sudah menunjuk ke key dengan state `Enabled`.
2. Jika sudah ada, exit tanpa mengubah key.
3. Jika belum ada:
   - menentukan `RSA_2048`, `RSA_3072`, atau `RSA_4096` berdasarkan private key;
   - membuat KMS key dengan `Origin=EXTERNAL` dan `KeyUsage=SIGN_VERIFY`;
   - memanggil `GetParametersForImport` dengan `RSA_AES_KEY_WRAP_SHA_256`;
   - mengonversi private key menjadi PKCS#8 DER;
   - membungkus material dengan AES Key Wrap with Padding;
   - mengenkripsi AES wrapping key dengan RSA-OAEP SHA-256;
   - menjalankan `ImportKeyMaterial`;
   - membuat alias stabil `alias/msign-hash-signing`.

Private key plaintext hasil konversi hanya dibuat sementara di `/tmp/kms-bootstrap.*` dan dibersihkan saat script selesai.

---

## 7. Start LocalStack

```bash
docker compose down
docker compose up -d
docker compose logs -f localstack
```

Target log:

```text
[kms-bootstrap] Bootstrap complete
```

Keluar dari stream log dengan `Ctrl + C`; ini tidak menghentikan container.

Cek container:

```bash
docker compose ps
```

Cek health endpoint dari Mac:

```bash
curl -s http://localhost:4566/_localstack/health
```

Expected minimum:

```json
{
  "services": {
    "kms": "running"
  },
  "edition": "community",
  "version": "4.14.0"
}
```

`http://localhost:4566` dapat terlihat putih bila dibuka langsung di browser. Itu normal: endpoint tersebut adalah AWS API endpoint, bukan dashboard web.

---

## 8. Verifikasi KMS alias dan key

```bash
docker compose exec -T localstack \
  awslocal kms describe-key \
  --region ap-southeast-1 \
  --key-id alias/msign-hash-signing \
  --query 'KeyMetadata.{KeyId:KeyId,KeyState:KeyState,Origin:Origin,KeyUsage:KeyUsage,KeySpec:KeySpec}' \
  --output table
```

Expected:

```text
KeyState: Enabled
Origin:   EXTERNAL
KeyUsage: SIGN_VERIFY
KeySpec:  RSA_2048
```

Lihat alias:

```bash
docker compose exec -T localstack \
  awslocal kms list-aliases \
  --region ap-southeast-1 \
  --output table
```

Aplikasi selalu menggunakan:

```text
alias/msign-hash-signing
```

Jangan hardcode `KeyId` UUID atau ARN.

---

## 9. Smoke test: KMS sign dan certificate verify

Command ini membuat SHA-256 digest, meminta KMS sign dengan `RSASSA_PKCS1_V1_5_SHA_256`, lalu memverifikasi signature memakai public key dari `signing.crt`.

```bash
docker compose exec -T localstack sh <<'SH'
set -eu

WORKDIR="$(mktemp -d /tmp/kms-sign-test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

printf 'localstack kms signing smoke test\n' > "$WORKDIR/message.txt"

openssl dgst -sha256 -binary \
  "$WORKDIR/message.txt" \
  > "$WORKDIR/digest.bin"

awslocal kms sign \
  --region ap-southeast-1 \
  --key-id alias/msign-hash-signing \
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

Expected:

```text
Signature Verified Successfully
```

Hasil ini membuktikan key yang diimport ke LocalStack KMS cocok secara kriptografis dengan `signing.crt`.

---

## 10. Integrasi hash-signing-service

### Service berjalan di Mac host

```env
SIGNER_BACKEND=awskms
AWS_KMS_REGION=ap-southeast-1
AWS_ENDPOINT_URL=http://localhost:4566
AWS_KMS_KEY_ID=alias/msign-hash-signing
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
```

### Service berjalan di OrbStack Linux VM

Dari OrbStack VM, `localhost` menunjuk VM, bukan macOS host. Gunakan:

```env
SIGNER_BACKEND=awskms
AWS_KMS_REGION=ap-southeast-1
AWS_ENDPOINT_URL=http://host.orb.internal:4566
AWS_KMS_KEY_ID=alias/msign-hash-signing
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
```

Cek dari VM:

```bash
curl http://host.orb.internal:4566/_localstack/health
```

Jika hasil health menunjukkan `kms: running`, jalur VM → macOS host → Docker Desktop → LocalStack sudah benar.

---

## 11. Validasi persistent bootstrap

Jalankan recreate test:

```bash
docker compose down
docker compose up -d

docker compose exec -T localstack \
  awslocal kms describe-key \
  --region ap-southeast-1 \
  --key-id alias/msign-hash-signing \
  --query 'KeyMetadata.{KeyId:KeyId,KeyState:KeyState,Origin:Origin,KeyUsage:KeyUsage,KeySpec:KeySpec}' \
  --output table
```

Validasi yang wajib lulus:

```text
alias/msign-hash-signing
  → KeyState: Enabled
  → Origin: EXTERNAL
  → KeyUsage: SIGN_VERIFY
```

`KeyId` boleh berubah setelah recreate. Itu normal karena bootstrap dapat membuat resource KMS baru. Alias harus tetap sama.

Untuk manual reconcile saat LocalStack sudah hidup:

```bash
docker compose exec -T localstack \
  /etc/localstack/init/ready.d/01-bootstrap-kms.sh
```

Jika alias sudah ada dan `Enabled`, command menjadi no-op yang aman.

---

## 12. Troubleshooting

### `License activation failed` / exit code 55

Penyebab umum: memakai `localstack/localstack:latest`.

Gunakan:

```yaml
image: localstack/localstack:4.14.0
```

### Alias atau key tidak ditemukan setelah restart/recreate

Pastikan mount bootstrap ada di `compose.yaml`:

```yaml
- "./import-rsa-key.sh:/etc/localstack/init/ready.d/01-bootstrap-kms.sh:ro"
```

Cek executable bit:

```bash
chmod +x import-rsa-key.sh
ls -l import-rsa-key.sh
```

Lalu:

```bash
docker compose down
docker compose up -d
docker compose logs --tail=200 localstack
```

Cari log:

```text
[kms-bootstrap] Bootstrap complete
```

### `/keys/msign` tidak ditemukan

Cek mount:

```bash
docker inspect localstack-kms \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
```

Pastikan host `keys` dipetakan ke `/keys`.

### `ImportKeyMaterial` menghasilkan `InternalError`

Pastikan bootstrap memakai Python untuk membuat AES key hex. Jangan gunakan `xxd`, karena image LocalStack ini tidak menyediakannya.

```sh
python3 -c 'import sys; print(open(sys.argv[1], "rb").read().hex())'
```

### VM tidak dapat akses `localhost:4566`

Dari OrbStack VM, gunakan:

```text
http://host.orb.internal:4566
```

Bukan `http://localhost:4566`.

### Browser membuka `http://localhost:4566` tetapi blank

Normal. Gunakan health endpoint:

```bash
curl -s http://localhost:4566/_localstack/health
```

---

## 13. Reset local environment

> Ini hanya untuk test environment. Perintah berikut menghapus LocalStack container dan local state/cache.

```bash
docker compose down
rm -rf volume/*
docker compose up -d
```

Bootstrap akan mengimpor key lagi dan membuat alias yang sama.

---

## 14. Security and limits

1. LocalStack bukan secure key store production.
2. Private key test/staging tetap sensitif dan tidak boleh dikomit atau dibagikan.
3. `keys` sebaiknya tetap berada pada private submodule atau secret storage lokal.
4. Bootstrap mengembalikan fungsi signing yang sama, tetapi tidak memberi HSM-backed non-exportability atau certification/compliance AWS KMS/CloudHSM.
5. `Signature Verified Successfully` hanya membuktikan kecocokan cryptographic key/certificate. Trust Adobe, AATL, LTV, timestamp, certificate chain, dan compliance harus diuji terpisah pada pipeline PDF lengkap.

---

## 15. Checklist

```text
[ ] Docker Desktop running
[ ] LocalStack health menunjukkan kms: running
[ ] /keys/msign/private.pem dapat dibaca LocalStack
[ ] private.pem dan signing.crt memiliki public-key hash yang sama
[ ] bootstrap script mounted ke ready.d
[ ] alias/msign-hash-signing resolve ke key Enabled
[ ] key Origin = EXTERNAL dan KeyUsage = SIGN_VERIFY
[ ] KMS Sign lolos "Signature Verified Successfully"
[ ] hash-signing-service memakai alias, bukan UUID/ARN
[ ] OrbStack VM memakai host.orb.internal:4566
[ ] keys/ dan volume/ tidak masuk repository publik
```
