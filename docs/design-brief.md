# Design Brief — Aplikasi Manajemen Inventaris Serverless (Week 12)

**Nama Lengkap:** Bagas Adjie Pamungkas  
**NIU:** 544718  
**Mata Kuliah:** Komputasi Awan — Individual Project Week 12  
**Repositori Git:** `https://github.com/TheGasz/aws-inventory-serverless`  
**Environment AWS:** `AWS Academy Sandbox (Account 420088380228) — Region us-east-1 (N. Virginia)`  
**Live HTTPS Endpoint:** `https://64dt355mqrfcea76jkd463bnxq0qhcvm.lambda-url.us-east-1.on.aws`

---

## 1. Use Case & Pemilihan Track
- **Use Case:** Sistem Manajemen Inventaris (*Inventory Management*) untuk mengelola data stok barang secara real-time (`sku`, `name`, `category`, `quantity`, `unit_price`, `location`, `created_at`, `updated_at`).
- **Track Terpilih:** **Track C — Serverless** (`AWS Lambda Function URL / API Gateway HTTP API v2` + `AWS Lambda Python 3.12` + `Amazon DynamoDB`).
- **Alasan Pemilihan:**
  1. **Reproducible untuk Sesi Sandbox 3 Jam:** Seluruh stack didefinisikan secara deklaratif (`infra/template.yaml`) dan otomatis (`scripts/deploy.ps1`), sehingga seluruh infrastruktur dapat dibangun ulang secara identik dalam hitungan detik setiap kali sesi Sandbox di-reset.
  2. **Efisiensi Biaya & Zero Server Overhead:** Seluruh layanan bersifat *pay-per-request* (biaya `$0` saat idle) tanpa VM EC2 atau NAT Gateway.
  3. **Lingkup Microservice Terukur:** Untuk memenuhi target Week 12 (`1 entity`, `CRUD endpoints`), implementasi difokuskan pada satu **Inventory Catalog Microservice** (*Single-Function Router Pattern*), disertai rancangan **Phase 2 Microservices** (*Stock Alert Lambda* via DynamoDB Streams + Amazon SNS).

## 2. Desain Arsitektur, Network, & Keamanan (IAM)
- **Temuan Lingkungan Sandbox & Keputusan Adaptif:**
  - Pada akun Sandbox (`420088380228`), kredensial `voclabs` menolak `dynamodb:CreateTable`, sedangkan IAM user `awsstudent` (`lab_policy`) mengizinkan `dynamodb:*`, `lambda:*`, `logs:*`, dan `cloudformation:*` di `us-east-1`, sementara `voclabs` menyediakan `iam:PassRole` untuk `LabRole`.
  - Karena `apigatewayv2` tidak tercantum dalam `lab_policy`, skrip deploy otomatis mengaktifkan **AWS Lambda Function URL (HTTPS Payload Format Version 2.0)** sebagai entrypoint publik aktif di Sandbox, sambil tetap menyediakan konfigurasi **API Gateway HTTP API v2** (throttling `10 RPS / burst 20`) pada `infra/template.yaml` dan `scripts/deploy.ps1` untuk target produksi.
- **Request & Data Flow:** Client mengirim request JSON via HTTPS (TLS 1.2+) ke Lambda Function URL -> Resource-Based Policy (`lambda:InvokeFunctionUrl` + `lambda:InvokeFunction` dengan kondisi `lambda:InvokedViaFunctionUrl=true`) memvalidasi pemanggilan -> Lambda `inventory-crud-handler` memvalidasi payload secara ketat -> mengeksekusi operasi `boto3` ke tabel DynamoDB `InventoryItems` -> menulis log JSON terstruktur ke CloudWatch Logs (`/aws/lambda/inventory-crud-handler`, retensi `7 days`).
- **Desain Network:** Berjalan pada *AWS-Managed Serverless Network* (`us-east-1`). Custom VPC sengaja tidak digunakan karena komunikasi Lambda ke DynamoDB dan CloudWatch sudah terenkripsi di atas backbone private AWS tanpa biaya NAT Gateway (~$32/bulan) maupun cold start ENI.
- **Keamanan & Least-Privilege IAM:** Eksekusi Sandbox memakai `LabRole` bawaan (zero hardcoded keys; memakai STS temporary credentials). Untuk target produksi, izin dibatasi pada 5 aksi CRUD DynamoDB (`PutItem`, `GetItem`, `Scan`, `UpdateItem`, `DeleteItem`) terhadap `arn:aws:dynamodb:us-east-1:<ACCOUNT_ID>:table/InventoryItems` dan Log Group `/aws/lambda/inventory-crud-handler:*`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InventoryDynamoCrud",
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:Scan",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem"
      ],
      "Resource": "arn:aws:dynamodb:us-east-1:<ACCOUNT_ID>:table/InventoryItems"
    },
    {
      "Sid": "LambdaCloudWatchLogsGroup",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": [
        "arn:aws:logs:us-east-1:<ACCOUNT_ID>:log-group:/aws/lambda/inventory-crud-handler",
        "arn:aws:logs:us-east-1:<ACCOUNT_ID>:log-group:/aws/lambda/inventory-crud-handler:*"
      ]
    }
  ]
}
```

## 3. Data Entity (`InventoryItems`) & Kontrak Endpoint CRUD
- **Entitas Tunggal (`InventoryItems`):**
  - Partition Key: `item_id` (String, UUID v4) | Capacity Mode: `PAY_PER_REQUEST` (On-Demand)
  - Atribut: `item_id`, `sku`, `name`, `category`, `quantity` (integer non-negatif), `unit_price` (`Decimal` non-negatif), `location`, `created_at` (UTC ISO-8601), `updated_at` (UTC ISO-8601).
- **4 Operasi CRUD & Endpoint Verifikasi:**
  - `GET /` & `GET /health` — Informasi layanan dan verifikasi koneksi nyata Lambda ke DynamoDB (`200 OK`).
  - `POST /items` (**Create**) — Validasi field wajib (`sku`, `name`, `quantity`, `unit_price`), menolak float di stok/negatif/`NaN`/`Infinity`, menyimpan item ke DynamoDB (`201 Created` / `400`).
  - `GET /items` (**Read All**) & `GET /items/{id}` (**Read One**) — Paginated `Scan` terurut descending `updated_at` dan `GetItem` (`200 OK` / `404`).
  - `PUT /items/{id}` (**Update**) — Partial update atomik dengan `ConditionExpression="attribute_exists(item_id)"` (`200 OK` / `400` / `404`).
  - `DELETE /items/{id}` (**Delete**) — Menghapus item dengan `ReturnValues="ALL_OLD"` (`200 OK` / `404`).
