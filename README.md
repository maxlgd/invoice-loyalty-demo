# Invoice Loyalty Demo — Salesforce + Data Cloud

A demo showing how a customer uploads an invoice through a portal, has it extracted by Data Cloud DocumentAI, gets each line item automatically matched against an internal product catalog, and earns loyalty points.

---

## What this demo shows

1. Customer uploads a PDF invoice through a self-service Experience Cloud page
2. Data Cloud DocumentAI extracts structured line items, dates, and totals
3. Each line item is matched against the internal product catalog (`Product2`) by SKU exact match
4. Matched items earn points immediately (1 point per dollar of purchase price)
5. Duplicate invoices are rejected using a SHA-256 fingerprint

---

## Architecture overview

```
Experience Cloud Page
  └─ Screen Flow: Invoice_Loyalty_Submission
       │
       ├─ Screen 1: File Upload
       │
       ├─ Apex Action: DocumentAIService
       │     └─ POST PDF binary → Data Cloud DocumentAI
       │           Named Credential: Data_Cloud_API
       │           DocumentAI config: <your-docai-config-api-name>
       │           └─ Returns raw JSON with extracted fields
       │
       └─ Apex Action: InvoiceLoyaltyProcessor
             ├─ Parse DocumentAI JSON
             ├─ Duplicate check (SHA-256 fingerprint on invoice# + supplier + total)
             ├─ Load Product2 catalog into memory
             ├─ For each line item:
             │     ├─ SKU exact match → SKU Match (eligible, points awarded)
             │     └─ No match → No Match (not eligible)
             ├─ Insert Invoice_Submission__c
             ├─ Attach original PDF via ContentDocumentLink
             └─ Insert Invoice_Line_Item__c records
```

---

## Data model

### `Invoice_Submission__c`
One record per invoice upload.

| Field | Type | Description |
|---|---|---|
| `Name` | Auto-number | Unique reference (INV-0001 etc.) |
| `Contact__c` | Lookup(Contact) | Customer who submitted — auto-populated from Experience Cloud running user |
| `Status__c` | Picklist | `Pending` → `Approved` / `Under Review` |
| `Invoice_Number__c` | Text(80) | Invoice number extracted by DocumentAI |
| `Invoice_Date__c` | Date | Invoice date extracted by DocumentAI |
| `Supplier_Name__c` | Text(255) | Supplier name extracted by DocumentAI |
| `Total_Amount_HT__c` | Currency | Total HT amount extracted by DocumentAI |
| `Total_Points_Awarded__c` | Number | Sum of points across all eligible line items |
| `Duplicate_Fingerprint__c` | Text(64), Unique | SHA-256 of `invoice_number\|supplier\|total_ht` — prevents re-submission |
| `Content_Document_Id__c` | Text | ContentDocumentId of the uploaded PDF |
| `Raw_JSON__c` | Long Text | Raw JSON from DocumentAI (stored for audit) |

### `Invoice_Line_Item__c`
One record per extracted line item. Child of `Invoice_Submission__c`.

| Field | Type | Description |
|---|---|---|
| `Invoice_Submission__c` | Master-Detail | Parent submission |
| `Reference__c` | Text(100) | SKU/reference code extracted from the invoice |
| `Product_Description__c` | Text(255) | Description extracted from the invoice |
| `Quantity__c` | Number | Quantity |
| `Unit_Price__c` | Currency | Unit price (HT) |
| `Match_Status__c` | Picklist | `SKU Match` / `No Match` |
| `Is_Eligible__c` | Checkbox | True if this item earns points |
| `Points_Awarded__c` | Number | `floor(Unit_Price × Quantity)` — 1 point per dollar |
| `Matched_Product_Id__c` | Lookup(Product2) | Matched catalog product |

### Product catalog
The internal catalog is **Product2** (standard Salesforce object). Active products with a `ProductCode` set are eligible for matching. No custom object needed.

---

## Apex classes

### `DocumentAIService.cls`
Sends the uploaded PDF to Data Cloud DocumentAI and returns the extracted JSON.

- Queries `ContentVersion.VersionData` to get the binary PDF
- Base64-encodes it and POSTs to the DocumentAI endpoint via the `Data_Cloud_API` Named Credential
- The DocumentAI config API name is hardcoded in this class — **update it to match yours** (see setup step 3)

### `InvoiceLoyaltyProcessor.cls`
Core processing class. Parses DocumentAI output, runs SKU matching, and creates all Salesforce records.

All SOQL reads happen before any DML — this is required by Salesforce's callout-before-DML rule.

### `DataCloudAssetService.cls`
Loads the `Product2` catalog into an in-memory `Map<String, EligibleAssetRecord>` keyed by uppercased `ProductCode`. Provides O(1) SKU lookups with no SOQL inside the matching loop.

---

## Setup checklist

### 1. Deploy the metadata

```bash
sf project deploy start --source-dir force-app -o <your-org-alias>
```

### 2. Populate Product2 records
Ensure your eligible products have `IsActive = true` and a non-blank `ProductCode`. These codes are matched against the `reference` field extracted from invoices (case-insensitive).

### 3. Configure the Named Credential
**Setup → Named Credentials → New**
- **API Name:** `Data_Cloud_API` — must match exactly, this is what `DocumentAIService.cls` uses
- **URL:** `https://<your-dc-tenant>.c360a.salesforce.com`
- **Authentication:** OAuth 2.0 via the Data Cloud Connected App

### 4. Configure DocumentAI and update the Apex
In **Data Cloud → Document AI**, create a configuration trained on your invoice PDFs. It must extract:

| Field | Notes |
|---|---|
| `invoice_number` | Invoice reference number |
| `invoice_date` | Date of issue |
| `supplier_name` | Vendor name |
| `total_amount_ht` | Pre-tax total (fallback: `total_ht`) |
| `items[]` | Array of line items |

Each item in `items` must expose: `reference`, `description`, `quantity`, `net_unit_price_ht` (fallbacks: `unit_price_ht`, `total_price_ht`).

Once created, open `DocumentAIService.cls` and update line 39 with your config's **API Name**:
```apex
'idpConfigurationIdOrName' => '<your-docai-config-api-name>'
```

### 5. Add the Flow to Experience Cloud
1. Experience Builder → your portal page
2. Drag a **Flow** component
3. Select `Invoice Loyalty Submission`
4. Publish

### 6. Field-level security
The Admin profile has full access. For Experience Cloud users, grant at minimum:
- Read/Write on `Invoice_Submission__c` and `Invoice_Line_Item__c`
- Apex class access: `DocumentAIService`, `InvoiceLoyaltyProcessor`
- Flow access: `Invoice_Loyalty_Submission`

---

## Project structure

```
invoice-loyalty-demo/
├── sfdx-project.json
├── Salesforce Data 360 APIs.postman_collection.json
├── Salesforce Data 360 Connect APIs.postman_collection.json
└── force-app/main/default/
    ├── classes/
    │   ├── DocumentAIService.cls          ← DocumentAI callout (update config name here)
    │   ├── DataCloudAssetService.cls      ← Product2 catalog loader + SKU lookup
    │   └── InvoiceLoyaltyProcessor.cls    ← Main processor: parse → match → create records
    ├── flows/
    │   └── Invoice_Loyalty_Submission.flow-meta.xml
    ├── objects/
    │   ├── Invoice_Submission__c/
    │   └── Invoice_Line_Item__c/
    ├── layouts/
    └── profiles/
        └── Admin.profile-meta.xml
```
