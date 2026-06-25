# LocalStack KMS

Repository ini berisi setup LocalStack untuk kebutuhan development dan integration test KMS secara lokal. Fokus utamanya adalah menjalankan service KMS, memakai key material RSA dari folder `keys`, lalu mengimpor key tersebut ke LocalStack KMS untuk flow `SIGN_VERIFY`.

Folder `keys` disimpan sebagai private Git submodule, sehingga isi private key dan certificate tidak ikut tampil di repository public.

## Stack yang Dibutuhkan

- Docker Desktop
- Docker Compose
- LocalStack `4.14.0`
- Bash / zsh
- Git dengan submodule support
- Akses ke private repository submodule `localstack-kms-keys`

Di dalam container LocalStack, script juga memakai:

- `awslocal`
- OpenSSL 3.x
- Python 3

## Struktur

```text
localstack-kms/
├── compose.yaml
├── import-rsa-key.sh
├── LOCALSTACK_KMS_IMPORTED_RSA_KEY.md
├── keys/                 # private submodule
└── volume/               # state/cache LocalStack lokal
```

## Clone

Untuk mengambil repo beserta submodule private:

```bash
git clone --recurse-submodules https://github.com/heruwaspodov/localstack-kms.git
cd localstack-kms
```

Jika sudah terlanjur clone tanpa submodule:

```bash
git submodule update --init --recursive
```

Catatan: akses ke `keys` hanya berhasil jika akun GitHub punya permission ke private repo submodule.

## Menjalankan LocalStack

```bash
docker compose up -d
```

Endpoint LocalStack tersedia di:

```text
http://127.0.0.1:4566
```

Service yang diaktifkan hanya `kms`, dengan region default `ap-southeast-1`.

## Import RSA Key

Pastikan `.localstack-kms-key-id` sudah berisi KMS key ID yang akan menerima external key material, lalu jalankan:

```bash
./import-rsa-key.sh
```

Script akan:

- mengambil wrapping public key dan import token dari LocalStack KMS
- mengubah private key ke PKCS#8 DER
- membungkus key material dengan `RSA_AES_KEY_WRAP_SHA_256`
- mengimpor key material ke LocalStack KMS
- menampilkan state akhir KMS key

Dokumentasi langkah lengkap ada di [LOCALSTACK_KMS_IMPORTED_RSA_KEY.md](LOCALSTACK_KMS_IMPORTED_RSA_KEY.md).

## Catatan Keamanan

Setup ini hanya untuk local development atau integration test. Jangan gunakan private key production sungguhan untuk eksperimen LocalStack.
