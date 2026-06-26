# LocalStack KMS

LocalStack KMS setup untuk local development dan integration test hash-signing. Repository ini mengimpor RSA private key dari private `keys` submodule ke LocalStack KMS dengan konfigurasi:

```text
KeyUsage: SIGN_VERIFY
Origin:   EXTERNAL
Alias:    alias/msign-hash-signing
```

> Ini hanya untuk local development / integration testing. LocalStack bukan AWS KMS, CloudHSM, atau HSM production.

## Persistent bootstrap, bukan persistent UUID

LocalStack Community `4.14.0` tidak boleh diasumsikan menyimpan imported KMS key secara andal setelah container dibuat ulang. Karena itu repository ini memakai **persistent bootstrap**:

1. Saat LocalStack mencapai stage `READY`, `import-rsa-key.sh` otomatis dijalankan.
2. Script mengecek alias `alias/msign-hash-signing`.
3. Bila alias sudah menunjuk ke key `Enabled`, script tidak melakukan apa pun.
4. Bila state key/alias hilang, script membuat key `EXTERNAL`, mengimpor `private.pem`, lalu membuat alias yang sama.

Dengan pendekatan ini, aplikasi selalu memakai alias stabil:

```text
alias/msign-hash-signing
```

UUID/ARN KMS dapat berubah setelah container recreate atau state LocalStack hilang. Jangan hardcode UUID/ARN di aplikasi.

## Requirements

- Docker Desktop
- Docker Compose
- LocalStack `4.14.0`
- Bash / zsh
- Git dengan submodule support
- Akses ke private submodule `localstack-kms-keys`

Container LocalStack sudah menyediakan:

- `awslocal`
- OpenSSL 3.x
- Python 3

## Repository structure

```text
localstack-kms/
├── compose.yaml
├── import-rsa-key.sh                  # READY-stage persistent bootstrap
├── LOCALSTACK_KMS_IMPORTED_RSA_KEY.md # detailed guide
├── keys/                              # private Git submodule; never public
│   └── msign/
│       ├── private.pem
│       ├── signing.crt
│       ├── root-ca.crt
│       └── sub-ca.crt
└── volume/                            # local cache/state; never commit
```

## Clone

```bash
git clone --recurse-submodules https://github.com/heruwaspodov/localstack-kms.git
cd localstack-kms
```

For an existing checkout:

```bash
git submodule update --init --recursive
```

The `keys` directory is a private submodule. GitHub access to that private repository is required.

## Docker Compose requirement

`compose.yaml` must mount both the private key directory and the bootstrap script:

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

    volumes:
      - "./keys:/keys:ro"
      - "./import-rsa-key.sh:/etc/localstack/init/ready.d/01-bootstrap-kms.sh:ro"
      - "./volume:/var/lib/localstack"
```

Make the script executable and commit its executable bit:

```bash
chmod +x import-rsa-key.sh
git update-index --chmod=+x import-rsa-key.sh
```

## Start LocalStack

```bash
docker compose up -d
docker compose logs -f localstack
```

Expected log after LocalStack is ready:

```text
[kms-bootstrap] Bootstrap complete
```

Check health:

```bash
curl -s http://localhost:4566/_localstack/health
```

Check the stable alias:

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

## Service configuration

### hash-signing-service runs on the Mac host

```env
SIGNER_BACKEND=awskms
AWS_KMS_REGION=ap-southeast-1
AWS_ENDPOINT_URL=http://localhost:4566
AWS_KMS_KEY_ID=alias/msign-hash-signing
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
```

### hash-signing-service runs in an OrbStack Linux VM

```env
SIGNER_BACKEND=awskms
AWS_KMS_REGION=ap-southeast-1
AWS_ENDPOINT_URL=http://host.orb.internal:4566
AWS_KMS_KEY_ID=alias/msign-hash-signing
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
```

From an OrbStack VM, `localhost` points to the VM itself. Use `host.orb.internal` to reach Docker Desktop running on macOS.

## Reconcile manually

The bootstrap runs automatically at every LocalStack start. To run it manually while LocalStack is already alive:

```bash
docker compose exec -T localstack \
  /etc/localstack/init/ready.d/01-bootstrap-kms.sh
```

If alias/key already exists and is `Enabled`, the command is a safe no-op.

## Verify after restart or recreate

```bash
docker compose down
docker compose up -d

docker compose exec -T localstack \
  awslocal kms describe-key \
  --region ap-southeast-1 \
  --key-id alias/msign-hash-signing \
  --query 'KeyMetadata.{KeyId:KeyId,KeyState:KeyState,Origin:Origin}' \
  --output table
```

The `KeyId` may change after a recreate. The required invariant is:

```text
alias/msign-hash-signing → Enabled RSA SIGN_VERIFY key
```

## Security

- Never commit `keys/`, `volume/`, private key conversions, or environment secrets.
- Use staging/test key material only.
- The bootstrap temporarily converts the private key to PKCS#8 DER inside `/tmp` and removes temporary files on exit.
- The `keys` mount is read-only, but the imported material can still exist in LocalStack runtime/state. Treat the entire local environment as sensitive.
- Passing the LocalStack test proves integration behavior only; it does not prove Adobe trust, AATL, LTV, legal/compliance validity, or equivalence with AWS KMS/HSM production.

For the full import algorithm, smoke test, troubleshooting, and reset procedure, read [LOCALSTACK_KMS_IMPORTED_RSA_KEY.md](LOCALSTACK_KMS_IMPORTED_RSA_KEY.md).
