# Serverless Inventory Management API — AWS Track C (Week 12)

Backend manajemen inventaris berbasis arsitektur serverless (**Amazon API Gateway HTTP API v2 + AWS Lambda Python 3.12 + Amazon DynamoDB**) yang dirancang **100% reproducible dalam < 60 detik** untuk menghadapi sesi **AWS Academy Sandbox 3 jam**.

## Re-Deploy Cepat Saat Sesi Sandbox Baru (3 Perintah)

Setiap kali sesi Sandbox 3 jam dimulai ulang (hari ini atau besok):

1. Buka portal AWS Academy Sandbox -> klik **Start Lab** -> buka **AWS Details -> AWS CLI -> Show** lalu **Copy** seluruh blok kredensial (`[default]`, `aws_access_key_id`, `aws_secret_access_key`, `aws_session_token`).
2. Jalankan 3 perintah berikut di **Windows PowerShell**:

```powershell
.\scripts\set-sandbox-creds.ps1
.\scripts\deploy.ps1
.\scripts\seed_and_test.ps1
```

- `set-sandbox-creds.ps1` menyimpan kredensial sementara ke `%USERPROFILE%\.aws\credentials` (di luar folder repo Git, aman dari leak).
- `deploy.ps1` bersifat **idempoten**: otomatis membuat/memperbarui DynamoDB `InventoryItems` (On-Demand), CloudWatch Log Group (retention 7 hari), Lambda `inventory-crud-handler` (`LabRole`), API Gateway `inventory-http-api` (6 route + CORS + throttling `10 RPS / burst 20`), dan `lambda:InvokeFunction` permission.
- `seed_and_test.ps1` mengisi 1 data sampel (`LAP-001`) lalu menguji siklus penuh `Health -> Create -> Read All -> Read One -> Update -> Negative 400 -> Delete -> Verify 404` dan menyimpan bukti ke `docs/evidence/04-api-crud-output.txt`.

> **Alternatif Infrastructure-as-Code (CloudFormation):** Jika Sandbox Anda mengizinkan CloudFormation, Anda juga dapat memakai `.\scripts\deploy-cfn.ps1` yang men-deploy `infra/template.yaml`.

## Arsitektur & Lingkup Microservice

- **Bounded Context:** Inventory Catalog Microservice (`1` entitas `InventoryItem`, `1` tabel `InventoryItems`, `1` router Lambda `inventory-crud-handler`).
- **Network:** AWS Managed Serverless Network (`us-east-1`, HTTPS TLS 1.2+) tanpa custom VPC untuk menghindari biaya NAT Gateway dan cold start ENI.
- **Security & IAM:** Eksekusi Sandbox memakai `LabRole` bawaan (sandbox boundary), disertai Resource-Based Policy `lambda:InvokeFunction`, stage throttling (`10 RPS / burst 20`), dan rancangan Least-Privilege IAM Policy untuk produksi.
- **Planned Phase 2:** Pemisahan *Stock Alert Microservice* berbasis DynamoDB Streams + Lambda + Amazon SNS.

## Struktur Repositori

```text
aws-inventory-serverless/
├── README.md
├── .gitignore
├── infra/
│   └── template.yaml              # CloudFormation IaC (zero IAM::Role creation)
├── lambda/
│   └── lambda_function.py         # Handler Python 3.12 (HTTP API v2.0 + REST API v1.0)
├── scripts/
│   ├── set-sandbox-creds.ps1      # Muat kredensial sementara Vocareum dari clipboard
│   ├── deploy.ps1                 # 1-command idempotent AWS CLI deployer
│   ├── deploy-cfn.ps1             # Alternatif deployer berbasis CloudFormation
│   ├── seed_and_test.ps1          # Uji E2E CRUD + simpan log bukti otomatis
│   └── destroy.ps1                # Teardown resource bersih
├── tests/
│   ├── event_health.json
│   ├── event_post_item.json
│   ├── event_get_items.json
│   ├── event_put_item.json
│   └── event_delete_item.json
└── docs/
    ├── design-brief.md
    └── evidence/
```

## Kontrak Endpoint API

Base URL dicatat otomatis ke `.last_api_url.txt` oleh script deploy: `https://<API_ID>.execute-api.us-east-1.amazonaws.com`

| Method | Path | Deskripsi | Status Sukses |
| :--- | :--- | :--- | :--- |
| `GET` | `/health` | Cek kesehatan API dan koneksi nyata ke DynamoDB | `200 OK` |
| `POST` | `/items` | Tambah item inventaris baru (`sku`, `name`, `quantity`, `unit_price`) | `201 Created` |
| `GET` | `/items` | Ambil seluruh daftar item (paginated `Scan`, urut `updated_at` desc) | `200 OK` |
| `GET` | `/items/{id}` | Ambil detail 1 item berdasarkan `item_id` | `200 OK` |
| `PUT` | `/items/{id}` | Perbarui sebagian/seluruh atribut item | `200 OK` |
| `DELETE` | `/items/{id}` | Hapus item berdasarkan `item_id` | `200 OK` |
