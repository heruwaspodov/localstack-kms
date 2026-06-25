# LocalStack KMS

This repository contains a LocalStack setup for local KMS development and integration testing. It runs the KMS service, uses RSA key material from the `keys` directory, and imports that key material into LocalStack KMS for the `SIGN_VERIFY` flow.

The `keys` directory is stored as a private Git submodule, so private keys and certificates are not exposed in the public repository.

## Required Stack

- Docker Desktop
- Docker Compose
- LocalStack `4.14.0`
- Bash / zsh
- Git with submodule support
- Access to the private `localstack-kms-keys` submodule repository

Inside the LocalStack container, the import script also uses:

- `awslocal`
- OpenSSL 3.x
- Python 3

## Structure

```text
localstack-kms/
├── compose.yaml
├── import-rsa-key.sh
├── LOCALSTACK_KMS_IMPORTED_RSA_KEY.md
├── keys/                 # private submodule
└── volume/               # local LocalStack state/cache
```

## Clone

Clone the repository together with its private submodule:

```bash
git clone --recurse-submodules https://github.com/heruwaspodov/localstack-kms.git
cd localstack-kms
```

If the repository was already cloned without submodules:

```bash
git submodule update --init --recursive
```

Note: the `keys` checkout only works if your GitHub account has access to the private submodule repository.

## Run LocalStack

```bash
docker compose up -d
```

The LocalStack endpoint is available at:

```text
http://127.0.0.1:4566
```

Only the `kms` service is enabled, with `ap-southeast-1` as the default region.

## Import RSA Key

Make sure `.localstack-kms-key-id` contains the KMS key ID that will receive the external key material, then run:

```bash
./import-rsa-key.sh
```

The script will:

- retrieve the wrapping public key and import token from LocalStack KMS
- convert the private key to PKCS#8 DER
- wrap the key material with `RSA_AES_KEY_WRAP_SHA_256`
- import the key material into LocalStack KMS
- print the final KMS key state

The full step-by-step documentation is available in [LOCALSTACK_KMS_IMPORTED_RSA_KEY.md](LOCALSTACK_KMS_IMPORTED_RSA_KEY.md).

## Security Notes

This setup is intended only for local development or integration testing. Do not use real production private keys for LocalStack experiments.
