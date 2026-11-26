# Serverless Inventory Management API — AWS Track C (Week 12)

**Nama:** Bagas Adjie Pamungkas | **NIU:** 544718  
**Repository:** https://github.com/TheGasz/aws-inventory-serverless  
**Live AWS Endpoint (Sandbox Session):** `https://64dt355mqrfcea76jkd463bnxq0qhcvm.lambda-url.us-east-1.on.aws`

Backend manajemen inventaris berbasis arsitektur serverless (**AWS Lambda Function URL / API Gateway HTTP API v2 + AWS Lambda Python 3.12 + Amazon DynamoDB**) yang dirancang **100% reproducible dalam < 60 detik** untuk menghadapi sesi **AWS Academy Sandbox 3 jam**.

## Re-Deploy Cepat Saat Sesi Sandbox Baru (3 Perintah)

Setiap kali sesi Sandbox 3 jam dimulai ulang:

1. Siapkan kredensial **`awsstudent`** (dari panel **Details -> Show**: `AccessKey` + `SecretKey`) serta profil **`voclabs`** (dari **AWS Details -> AWS CLI -> Show** untuk `iam:PassRole` ke `LabRole`).
2. Jalankan perintah berikut di **Windows PowerShell**:

```powershell
.\scripts\set-sandbox-creds.ps1 -AccessKey "<AWSSTUDENT_ACCESS_KEY>" -SecretKey "<AWSSTUDENT_SECRET_KEY>"
.\scripts\deploy.ps1 -Region us-east-1
.\scripts\seed_and_test.ps1
```

- `deploy.ps1` bersifat **idempoten**: otomatis membuat/memperbarui DynamoDB `InventoryItems` (On-Demand), CloudWatch Log Group (retention 7 hari), Lambda `inventory-crud-handler` (`LabRole`), dan entrypoint HTTPS (**API Gateway HTTP API v2** jika diizinkan, atau fallback otomatis ke **Lambda Function URL** dengan CORS & public resource-based policy).
- `seed_and_test.ps1` mengisi 1 data sampel (`LAP-001`) lalu menguji siklus penuh `Health -> Create -> Read All -> Read One -> Update -> Negative 400 -> Delete -> Verify 404` dan menyimpan bukti ke `docs/evidence/04-api-crud-output.txt`.

> **Alternatif Infrastructure-as-Code (CloudFormation):** Tersedia di `infra/template.yaml` dan `.\scripts\deploy-cfn.ps1` untuk environment yang mengizinkan `apigatewayv2`.

## Arsitektur & Lingkup Microservice

- **Bounded Context:** Inventory Catalog Microservice (`1` entitas `InventoryItem`, `1` tabel `InventoryItems`, `1` router Lambda `inventory-crud-handler`).
- **Network:** AWS Managed Serverless Network (`us-east-1`, HTTPS TLS 1.2+) tanpa custom VPC untuk menghindari biaya NAT Gateway dan cold start ENI.
- **Security & IAM:** Eksekusi Sandbox memakai `LabRole` bawaan (sandbox boundary), disertai Resource-Based Policy (`lambda:InvokeFunctionUrl` + `lambda:InvokeFunction`) dan rancangan Least-Privilege IAM Policy untuk produksi.
- **Planned Phase 2:** Pemisahan *Stock Alert Microservice* berbasis DynamoDB Streams + Lambda + Amazon SNS.

## Struktur Repositori

```text
aws-inventory-serverless/
├── README.md
├── .gitignore
├── infra/
│   └── template.yaml                  # CloudFormation IaC (zero IAM::Role creation)
├── lambda/
│   └── lambda_function.py             # Handler Python 3.12 (HTTP API v2, Function URL, REST v1)
├── scripts/
│   ├── set-sandbox-creds.ps1          # Muat kredensial awsstudent / STS ke ~/.aws/credentials
│   ├── deploy.ps1                     # 1-command idempotent AWS CLI deployer + Function URL fallback
│   ├── deploy-cfn.ps1                 # Alternatif deployer berbasis CloudFormation
│   ├── seed_and_test.ps1              # Uji E2E CRUD + simpan log bukti otomatis
│   └── destroy.ps1                    # Teardown resource bersih
├── tests/
│   ├── event_health.json
│   ├── event_post_item.json
│   ├── event_get_items.json
│   ├── event_put_item.json
│   └── event_delete_item.json
└── docs/
    ├── architecture-track-c.svg       # Diagram arsitektur vektor (source)
    ├── architecture-track-c.png       # Diagram arsitektur resolusi tinggi
    ├── design-brief.md                # Design Brief Week 12 (NIU 544718)
    └── evidence/
        ├── 01-dynamodb-evidence.json
        ├── 02-lambda-evidence.json
        ├── 03-cloudwatch-logs.json
        ├── 04-api-crud-output.txt
        ├── 05-live-health-browser.png
        └── 06-live-items-browser.png
```

## Kontrak Endpoint API

Base URL dicatat otomatis ke `.last_api_url.txt` oleh script deploy: `https://64dt355mqrfcea76jkd463bnxq0qhcvm.lambda-url.us-east-1.on.aws`

| Method | Path | Deskripsi | Status Sukses |
| :--- | :--- | :--- | :--- |
| `GET` | `/` | Info layanan & daftar endpoint | `200 OK` |
| `GET` | `/health` | Cek kesehatan API dan koneksi nyata ke DynamoDB | `200 OK` |
| `POST` | `/items` | Tambah item inventaris baru (`sku`, `name`, `quantity`, `unit_price`) | `201 Created` |
| `GET` | `/items` | Ambil seluruh daftar item (paginated `Scan`, urut `updated_at` desc) | `200 OK` |
| `GET` | `/items/{id}` | Ambil detail 1 item berdasarkan `item_id` | `200 OK` |
| `PUT` | `/items/{id}` | Perbarui sebagian/seluruh atribut item | `200 OK` |
| `DELETE` | `/items/{id}` | Hapus item berdasarkan `item_id` | `200 OK` |
