# Invoice-to-Loyalty: An End-to-End Demo with Data Cloud DocumentAI and Salesforce Flows

*A technical walkthrough for Salesforce architects*

---

## The problem we're solving

B2B loyalty programs often ask customers to upload paper or PDF invoices to claim reward points. The manual review process is slow, error-prone, and doesn't scale. This demo automates the entire journey — from PDF upload to points awarded — using two Salesforce platform capabilities that are rarely seen together:

1. **Data Cloud DocumentAI** — extracts structured data from unstructured invoices
2. **Salesforce Flows + Apex** — orchestrates the whole thing inside an Experience Cloud self-service portal

---

## Architecture at a glance

```
Customer (Experience Cloud portal)
  └─ Uploads a PDF invoice
        │
        ▼
  Screen Flow: Invoice_Loyalty_Submission
        │
        ├─ [Apex] DocumentAIService
        │     └─ POST PDF (base64) → Data Cloud DocumentAI
        │           Config: Intuis_Invoice_Extraction
        │           Returns: JSON with invoice_number, supplier_name,
        │                    total_amount_ht, items[]
        │
        ├─ [Apex] InvoiceLoyaltyProcessor
        │     ├─ Parse DocumentAI JSON
        │     ├─ Duplicate check (SHA-256 fingerprint)
        │     ├─ Load Product2 catalog into memory
        │     └─ For each line item:
        │           ├─ SKU exact match (ProductCode)  → SKU Match ✓ — points awarded
        │           └─ No SKU match                   → No Match  ✗ — no points
        │
        ├─ Decision: Duplicate?  → "Already submitted" screen
        └─ Decision: Success?    → Confirmation screen (shows total points)
```

---

## Data model

Two custom objects, plus `Product2` as the catalog.

### `Invoice_Submission__c` — one record per uploaded invoice

| Field | Type | Notes |
|---|---|---|
| `Name` | Auto-number | Format: INV-0001 |
| `Contact__c` | Lookup(Contact) | Auto-populated from the Experience Cloud running user |
| `Status__c` | Picklist | `Pending` → `Approved` or `Under Review` |
| `Invoice_Number__c` | Text(80) | Extracted by DocumentAI |
| `Invoice_Date__c` | Date | Extracted by DocumentAI |
| `Supplier_Name__c` | Text(255) | Extracted by DocumentAI |
| `Total_Amount_HT__c` | Currency | Extracted by DocumentAI |
| `Total_Points_Awarded__c` | Number | Sum of all eligible line items |
| `Duplicate_Fingerprint__c` | Text(64), **Unique** | SHA-256 of `invoice_number\|supplier\|total_ht` |
| `Content_Document_Id__c` | Text | ID of the uploaded PDF |
| `Raw_JSON__c` | Long Text Area | Full DocumentAI response — audit trail |

**Status flow:**
- Starts as `Pending` during processing
- → `Approved` when at least one point was awarded
- → `Under Review` when no points could be awarded (no SKU matches)

### `Invoice_Line_Item__c` — one record per extracted line item

| Field | Type | Notes |
|---|---|---|
| `Invoice_Submission__c` | Master-Detail | Parent submission |
| `Reference__c` | Text(100) | SKU code from the invoice |
| `Product_Description__c` | Text(255) | Free-text description from the invoice |
| `Quantity__c` | Number | |
| `Unit_Price__c` | Currency | |
| `Match_Status__c` | Picklist | `SKU Match` / `No Match` |
| `Is_Eligible__c` | Checkbox | True = earns points |
| `Points_Awarded__c` | Number | `floor(Unit_Price × Quantity)` |
| `Matched_Product_Id__c` | Lookup(Product2) | Matched catalog product |

### Product catalog — `Product2` (standard object)

No custom catalog object needed. Any active `Product2` record with a non-blank `ProductCode` is eligible for matching. The `ProductCode` is what the invoice `reference` field is matched against.

---

## Component deep-dive

### 1. DocumentAIService.cls

The entry point. The flow calls it as an Invocable Action immediately after the customer uploads the PDF.

**What it does:**
1. Queries `ContentVersion.VersionData` using the `ContentDocumentId` from the file upload component
2. Base64-encodes the binary
3. POSTs to the Data Cloud DocumentAI endpoint via the `Data_Cloud_API` Named Credential:
   ```
   POST callout:Data_Cloud_API/services/data/v63.0/ssot/document-processing/actions/extract-data
   ```
4. The request body references the DocumentAI configuration by its API name — this config defines which fields to extract
5. Returns the raw JSON response body to the flow

**Key design decision:** The class is deliberately thin — it only handles the HTTP call and passes the raw JSON upstream. All parsing happens in `InvoiceLoyaltyProcessor`, which makes it easy to swap out the DocumentAI config without touching the orchestration logic.

```apex
Map<String, Object> requestBody = new Map<String, Object>{
    'idpConfigurationIdOrName' => 'Intuis_Invoice_Extraction', // ← hardcoded in DocumentAIService.cls line 39
    'files' => new List<Object>{
        new Map<String, Object>{
            'mimeType' => mimeType,
            'data'     => base64Data
        }
    }
};
```

> **Two names must match:** the string `'Intuis_Invoice_Extraction'` in `DocumentAIService.cls` line 39 must exactly match the **API Name** of your DocumentAI configuration in Data Cloud (not the label — the API name, visible in the URL or the config detail page). If you rename your config or reuse this code for a different customer, update that string.
>
> Similarly, `callout:Data_Cloud_API` (same line 47) must match the **API Name** of your Named Credential in **Setup → Named Credentials**. The credential is named `Data_Cloud_API` in this project — if yours differs, update the endpoint string in `DocumentAIService.cls` line 47.

---

### 2. InvoiceLoyaltyProcessor.cls

The core of the demo. This class has one job: take the DocumentAI JSON response and turn it into Salesforce records, with product matching along the way.

**Processing order**

The class is structured in four clear phases:

```
Phase 1 — Parse
  1. Decode the DocumentAI JSON (handles HTML entity encoding from the API)
  2. Extract: invoice_number, supplier_name, total_amount_ht, items[]

Phase 2 — Duplicate check (SOQL)
  3. Compute SHA-256 fingerprint
  4. Query Invoice_Submission__c — return early if found

Phase 3 — Resolve line items (SOQL only, no DML)
  5. Load Product2 catalog into memory map
  6. For each line item: attempt SKU match → record decision

Phase 4 — Persist (DML only)
  7. insert Invoice_Submission__c
  8. insert ContentDocumentLink (attach original PDF)
  9. insert Invoice_Line_Item__c records
  10. update Invoice_Submission__c (set total points and status)
```

**Duplicate detection with SHA-256**

Before touching any record, the processor computes a fingerprint from the three most stable identifiers on an invoice:

```apex
String num      = invoiceNumber.trim().toUpperCase();
String supplier = supplierName.trim().toUpperCase().replaceAll('[^A-Z0-9]', '');
String amount   = String.valueOf(totalHt.setScale(2));
Blob hash = Crypto.generateDigest('SHA-256', Blob.valueOf(num + '|' + supplier + '|' + amount));
String fingerprint = EncodingUtil.convertToHex(hash); // 64-char hex
```

The normalisation step matters: stripping non-alphanumeric characters from the supplier name means `"ACME Corp."` and `"ACME CORP"` produce the same hash. The `Duplicate_Fingerprint__c` field is marked `Unique`, so even a race condition would throw a duplicate key error rather than create a second record. If the fingerprint is found, the processor returns immediately — no records are created, no points touched.

**SKU matching**

The Product2 catalog is loaded once into a `Map<String, EligibleAssetRecord>` keyed by uppercased `ProductCode`. Each line item's `reference` field is trimmed, uppercased, and looked up in the map — O(1) per item, no SOQL inside the loop.

```
Reference__c "rad-1500-w" → lookup "RAD-1500-W" → found → SKU Match, Is_Eligible = true
Reference__c "XYZ-999"    → lookup "XYZ-999"    → miss  → No Match,  Is_Eligible = false
```

**Points formula:** `floor(Unit_Price × Quantity)` — 1 point per dollar, per eligible line item.

---

### 3. DataCloudAssetService.cls

A catalog loader. It queries all active `Product2` records with a non-null `ProductCode` and returns them as a `Map<String, EligibleAssetRecord>` keyed by uppercased `ProductCode`. Built once per transaction and passed by reference to the matching loop.

---

## The Flow

### Invoice_Loyalty_Submission (customer-facing Screen Flow)

This is what the Experience Cloud page hosts.

| Step | Detail |
|---|---|
| Screen: Upload Invoice | Instructions + Lightning file upload component |
| Apex: DocumentAIService | Sends the PDF to Data Cloud DocumentAI |
| Decision: Extraction OK? | If DocumentAI fails → error screen |
| Apex: InvoiceLoyaltyProcessor | Full processing: parse, match, insert records |
| Decision: Duplicate? | Amber warning screen if the invoice was already submitted |
| Decision: Success? | Confirmation screen (shows total points) or error screen |

The flow passes `ContentDocumentId` (from the file upload component) into both Apex actions, and optionally passes the running user's `ContactId` into `InvoiceLoyaltyProcessor` — the class looks it up from `UserInfo` if that variable is blank.

---

## Data Cloud setup

### Named Credential: `Data_Cloud_API`

All callouts use `callout:Data_Cloud_API` as the base URL. Configure in **Setup → Named Credentials**:

- **URL:** `https://<your-dc-tenant>.c360a.salesforce.com`
- **Authentication:** OAuth 2.0 via the Data Cloud Connected App
- **Scope:** `api`

The API name of the Named Credential must be `Data_Cloud_API` — that string is hardcoded in `DocumentAIService.cls` line 47. If you use a different name, update that line.

### DocumentAI configuration: `Intuis_Invoice_Extraction`

In **Data Cloud → Document AI**, create (or verify) a configuration with the **API Name** `Intuis_Invoice_Extraction`. It must be trained or configured to extract the following fields from invoice PDFs:

> The API Name (not the label) must match the string `'Intuis_Invoice_Extraction'` hardcoded in `DocumentAIService.cls` line 39. To find the API Name of an existing config: open it in Data Cloud → Document AI and check the URL or the detail panel — it is the developer name, not the display label.

**Header fields:**

| Field name | Type | Notes |
|---|---|---|
| `invoice_number` | Text | Invoice reference number |
| `invoice_date` | Date | Date of issue |
| `supplier_name` | Text | Vendor/supplier name |
| `total_amount_ht` | Number | Pre-tax total (fallback: `total_ht`) |
| `items` | Array | One entry per line item |

**Per-item fields (inside `items`):**

| Field name | Type | Notes |
|---|---|---|
| `reference` | Text | SKU / product reference code |
| `description` | Text | Free-text product description |
| `quantity` | Number | |
| `net_unit_price_ht` | Number | Unit price pre-tax (fallbacks: `unit_price_ht`, then `total_price_ht`) |

The code handles HTML entity encoding in the DocumentAI response (`&quot;`, `&amp;`, etc.) — this is expected from the current API format.

---

## Setup checklist

Follow these steps in order when deploying to a new scratch org or sandbox.

### Step 1 — Deploy the metadata

```bash
# Full deploy
sf project deploy start --source-dir force-app -o <your-org-alias>

# Or piece by piece if you're iterating
sf project deploy start --source-dir force-app/main/default/classes -o <your-org-alias>
sf project deploy start --source-dir force-app/main/default/objects  -o <your-org-alias>
sf project deploy start --source-dir force-app/main/default/flows    -o <your-org-alias>
```

### Step 2 — Populate Product2 records

The SKU matching runs against `Product2.ProductCode`. Load at least a handful of products with `IsActive = true` and the ProductCodes that appear in your test invoices. Matching is case-insensitive.

```
Product2.Name        = "Radiateur à inertie 1500W"
Product2.ProductCode = "RAD-1500-W"
Product2.IsActive    = true
```

### Step 3 — Configure the Named Credential

**Setup → Named Credentials → New**

- **API Name:** `Data_Cloud_API` — must match exactly, this is what `DocumentAIService.cls` line 47 references
- **URL:** `https://<your-dc-tenant>.c360a.salesforce.com`
- **Authentication:** OAuth 2.0 via the Data Cloud Connected App

### Step 4 — Configure DocumentAI

In **Data Cloud → Document AI**, create a configuration and set its **API Name** to `Intuis_Invoice_Extraction` — this must match the string on `DocumentAIService.cls` line 39. Train it on representative invoice PDFs and make sure the configuration is **Active** before testing.

To find the API Name of an existing config: open it in Data Cloud → Document AI and look at the developer name in the URL or detail panel (it is distinct from the display label).

### Step 5 — Add the customer flow to Experience Cloud

1. Open **Experience Builder** on your portal
2. Drag a **Flow** component onto the page
3. Select `Invoice Loyalty Submission`
4. Publish the page

### Step 6 — Field-level security

The `Admin.profile-meta.xml` included in the repo grants full access. For Experience Cloud guest/authenticated users, grant at minimum:

- **Object permissions:** Read + Create on `Invoice_Submission__c` and `Invoice_Line_Item__c`
- **Apex class access:** `DocumentAIService`, `InvoiceLoyaltyProcessor`
- **Flow access:** `Invoice_Loyalty_Submission`

---

## Testing the demo end-to-end

### Happy path — SKU match

1. Log in as an Experience Cloud user
2. Navigate to the portal page with the flow
3. Upload a PDF invoice that contains at least one line item whose `reference` field matches a `Product2.ProductCode` in your org
4. The flow completes and shows the confirmation screen with a point total
5. Check `Invoice_Submission__c` — status should be `Approved`, `Total_Points_Awarded__c` should reflect `floor(unit_price × qty)` for each matched item
6. Check `Invoice_Line_Item__c` children — `Match_Status__c = SKU Match`, `Is_Eligible__c = true`

### Duplicate detection

Re-submit the same invoice PDF. The flow should route to the amber duplicate warning screen. No new `Invoice_Submission__c` record should be created.

### No-match path

Upload an invoice whose line items have no matching SKU in Product2. The submission is created with status `Under Review`, all line items have `Match_Status__c = No Match`, and `Total_Points_Awarded__c = 0`.

### DocumentAI failure

Upload a non-invoice document (e.g., a blank PDF). The flow should route to the error screen after DocumentAI fails to extract the expected fields.

---

## Key design patterns worth noting

**Phase-separated Apex** — `InvoiceLoyaltyProcessor` never mixes SOQL/callouts with DML in arbitrary order. All reads and decisions are completed first, then all writes happen in sequence. This is the correct pattern any time you process external data before persisting it, and it avoids the callout-after-DML error if you later add an HTTP call.

**SHA-256 fingerprinting for deduplication** — normalising the three key invoice fields before hashing makes the check robust to minor formatting differences (punctuation in supplier names, decimal formats) without requiring a fuzzy-match query.

**In-memory catalog map** — the Product2 catalog is loaded once per transaction into a `Map<String, EligibleAssetRecord>` and passed by reference into the matching loop. No SOQL per line item.

**Flow as the orchestrator** — the Apex classes are invocable actions with clean input/output contracts. The Flow owns all the routing logic (duplicate? error?). This makes it easy to adjust the UX or add new screens without touching Apex.

---

## Repository structure

```
invoice-loyalty-demo/
├── sfdx-project.json
├── Salesforce Data 360 APIs.postman_collection.json          ← Data Cloud API reference
├── Salesforce Data 360 Connect APIs.postman_collection.json  ← Data Cloud Connect API reference
└── force-app/main/default/
    ├── classes/
    │   ├── DocumentAIService.cls            ← DocumentAI HTTP callout
    │   ├── DataCloudAssetService.cls        ← Product2 catalog loader + SKU lookup
    │   └── InvoiceLoyaltyProcessor.cls      ← Main orchestrator: parse → match → persist
    ├── flows/
    │   └── Invoice_Loyalty_Submission.flow-meta.xml    ← Customer-facing upload flow
    ├── objects/
    │   ├── Invoice_Submission__c/
    │   ├── Invoice_Line_Item__c/
    │   └── Eligible_Asset__c/               ← Legacy, unused
    ├── layouts/
    └── profiles/
        └── Admin.profile-meta.xml
```
