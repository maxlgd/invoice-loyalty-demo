# Invoice Loyalty Demo — Salesforce + Data Cloud

A demo showing how a customer uploads an invoice through a portal, has it extracted by Data360 DocumentAI, gets each line item automatically matched against an internal product catalog, and earns loyalty points. Items that can't be auto-matched are queued for human review.

---

## What this demo shows

1. Customer uploads a PDF invoice through a self-service Experience Cloud page
2. Data Cloud DocumentAI extracts structured line items, dates, and totals
3. Each line item is matched against the internal product catalog (Product2) in two stages:
   - **Stage 1 — SKU exact match:** the invoice `reference` field is compared against `Product2.ProductCode`
4. Auto-matched items earn points immediately (1 point per dollar of purchase price)
5. Duplicate invoices are rejected silently using a SHA-256 fingerprint
6. The original PDF is attached to the submission record so reviewers can compare it against extracted data

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
       │           DocumentAI config: Intuis_Invoice_Extraction
       │           └─ Returns raw JSON with extracted fields
       │
       ├─ Apex Action: InvoiceLoyaltyProcessor
       │     ├─ Parse DocumentAI JSON
       │     ├─ Duplicate check (SHA-256 fingerprint on invoice# + supplier + total)
       │     ├─ Load Product2 catalog into memory (callout)
       │     ├─ For each line item:
       │     │     ├─ SKU exact match → SKU Match (score=1.0, eligible)
       │     │     ├─ Vector score ≥ 0.85 → Vector Match (eligible, auto-awarded)
       │     │     ├─ Vector score 0.55–0.84 → Pending Review (held for human)
       │     │     └─ No match → No Match (score=0, not eligible)
       │     ├─ Insert Invoice_Submission__c
       │     ├─ Attach original PDF via ContentDocumentLink
       │     └─ Insert Invoice_Line_Item__c records
       │
       ├─ Decision: Duplicate? → Screen: Already submitted
       ├─ Decision: Success? → Screen: Confirmation (points total)
       │                    → Screen: Error message
       │
       └─ Submissions with "Pending Review" items → status "Under Review"
             └─ Internal reviewer launches "Invoice Line Item Review" flow
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
| `Raw_JSON__c` | Long Text | Parsed JSON from DocumentAI (stored for audit) |

**Status flow:**
- Starts as `Pending` during processing
- → `Approved` when all items are resolved and at least one point was awarded
- → `Under Review` when any item is still `Pending Review` (needs human review)

### `Invoice_Line_Item__c`
One record per extracted line item. Child of `Invoice_Submission__c`.

| Field | Type | Description |
|---|---|---|
| `Invoice_Submission__c` | Master-Detail | Parent submission |
| `Reference__c` | Text(100) | SKU/reference code extracted from the invoice |
| `Product_Description__c` | Text(255) | Description extracted from the invoice |
| `Quantity__c` | Number | Quantity |
| `Unit_Price__c` | Currency | Unit price (HT) |
| `Match_Status__c` | Picklist | `SKU Match` / `Vector Match` / `Pending Review` / `Approved by Reviewer` / `Rejected by Reviewer` / `No Match` |
| `Is_Eligible__c` | Checkbox | True if this item earns points |
| `Points_Awarded__c` | Number | `floor(Unit_Price × Quantity)` — 1 point per dollar |
| `Vector_Score__c` | Number(5,4) | Similarity score from Data Cloud hybrid search (0 if no vector search ran) |
| `Match_Confidence__c` | Number(5,1) | Score × 100, displayed as a percentage |
| `Matched_Product_Id__c` | Lookup(Product2) | Matched catalog product |
| `Suggested_Product_Name__c` | Text(255) | Name of the matched product (for reviewer display) |

### Product catalog
The internal catalog is **Product2** (standard Salesforce object). Active products with a `ProductCode` set are eligible for matching. No custom object needed.

---

## Apex classes

### `DocumentAIService.cls`
Sends the uploaded PDF to Data Cloud DocumentAI and returns the extracted JSON.

**Inputs:** `contentDocumentId` (String)
**Outputs:** `rawJson` (String), `success` (Boolean), `errorMessage` (String)

**How it works:**
1. Queries `ContentVersion.VersionData` to get the binary PDF
2. Base64-encodes the binary
3. POSTs to `callout:Data_Cloud_API/services/data/v63.0/ssot/document-processing/actions/extract-data`
4. Uses DocumentAI config `Intuis_Invoice_Extraction`
5. Returns the raw HTTP response body as `rawJson`

---

### `InvoiceLoyaltyProcessor.cls`
Core processing class. Parses DocumentAI output, runs product matching, and creates all Salesforce records.

**Inputs:** `rawJson` (DocumentAI HTTP response), `contentDocumentId`, optional `contactId`
**Outputs:** `submissionId`, `totalPoints`, `hasPending`, `success`, `isDuplicate`, `errorMessage`

**Processing order (callout-before-DML rule):**

All HTTP callouts must happen before any DML in a Salesforce transaction. The class is structured accordingly:

```
1. Parse DocumentAI JSON
2. Duplicate fingerprint check (SOQL)
3. Load Product2 catalog (SOQL — not a callout)
4. For each line item: run DataCloudVectorSearch.search() if SKU misses (callout)
   ↑ All MatchDecision objects computed here, stored in memory
5. insert Invoice_Submission__c                          ← DML starts here
6. insert ContentDocumentLink (PDF attachment)
7. insert Invoice_Line_Item__c records
8. update Invoice_Submission__c (points + status)
```

**Duplicate detection:**

Before creating any record, the processor checks whether this invoice has already been submitted. The check uses a SHA-256 fingerprint stored in `Duplicate_Fingerprint__c` (unique field on `Invoice_Submission__c`).

The fingerprint is computed from three extracted fields, normalised so that minor formatting differences don't bypass the check:

| Input | Normalisation applied |
|---|---|
| `invoice_number` | Trimmed, uppercased |
| `supplier_name` | Trimmed, uppercased, all non-alphanumeric characters removed |
| `total_amount_ht` | Formatted to exactly 2 decimal places (e.g. `"123.40"`) |

These three values are joined with `|` as a separator and hashed:

```
SHA-256( "261377214|INTUIS|1234.56" )  →  64-character hex string
```

The SOQL check runs before any DML or callout:

```apex
if (![SELECT Id FROM Invoice_Submission__c WHERE Duplicate_Fingerprint__c = :fingerprint LIMIT 1].isEmpty()) {
    result.isDuplicate = true;
    result.errorMessage = 'This invoice has already been submitted (invoice number: ' + invoiceNumber + ').';
    return result;
}
```

If a match is found, the processor returns immediately — nothing is inserted, no points are touched. The Flow routes to a dedicated amber warning screen telling the customer the invoice was already processed.

**Edge cases handled:**
- If `invoice_number` is blank (DocumentAI couldn't extract it), the fingerprint uses an empty string for that component — the check still runs
- If `supplier_name` is null (common — not all invoice formats expose it), it normalises to `""` — two invoices from different suppliers but with the same number and total would collide, which is intentional for this demo
- If `total_amount_ht` can't be extracted from the top-level fields, the processor falls back to summing `total_price_ht` across all line items before computing the fingerprint

**Matching tiers:**

| Tier | Condition | Match_Status | Is_Eligible | Score |
|---|---|---|---|---|
| SKU Match | `Reference__c` matches `Product2.ProductCode` exactly (case-insensitive) | `SKU Match` | true | 1.0 |
| Vector Match | Hybrid search score ≥ 0.85 | `Vector Match` | true | actual score |
| Pending Review | Hybrid search score 0.55–0.84 | `Pending Review` | false (until approved) | actual score |
| No Match | No SKU match, vector null or score < 0.55 | `No Match` | false | 0 |

**Points formula:** `floor(Unit_Price__c × Quantity__c)` — 1 point per dollar.

---

### `DataCloudAssetService.cls`
Loads the Product2 catalog into an in-memory map for O(1) SKU lookups.

**Key method:** `loadCatalogByCode()` — returns `Map<String, EligibleAssetRecord>` keyed by `ProductCode.toUpperCase()`.

**Key method:** `findByProductCode(reference, catalog)` — trims and uppercases the invoice reference, looks it up in the map.

Only `IsActive = true` products with a non-null `ProductCode` are included.

---

### `DataCloudVectorSearch.cls`
Calls Data Cloud hybrid search for description-based matching when SKU fails.

**SQL used:**
```sql
SELECT ssot__Id__c, ssot__Name__c, ssot__ProductCode__c, score
FROM HYBRID_SEARCH(TABLE(Product_index_chunk__dlm), '<description>', 'Product_index', 1)
```

**Endpoint:** `callout:Data_Cloud_API/services/data/v63.0/ssot/query`

**Thresholds:**
- `AUTO_MATCH_THRESHOLD = 0.85` — auto-approved, points awarded immediately
- `PENDING_REVIEW_THRESHOLD = 0.55` — held for human review

Returns `null` on any error (graceful degradation — the caller treats null as No Match and the rest of the invoice processes normally).

**Current status:** The `HYBRID_SEARCH` SQL function is correctly implemented but fails at runtime across this entire org with: `"embeddingModelDetails and vectorDbConnectionDetails both can not be empty"`. This is an org-level provisioning issue — the vector search runtime service is not enabled. All indexes in the org (`e5_large_v2` and `multilingual-e5-large`) fail the same way. **A Salesforce Support case is needed** to enable the Vector Search Query runtime on tenant `a360/prod/f4dbe78da3bb409e84e6ff29666bd7cf`.

**Impact while blocked:** SKU matching works perfectly. Items without a matching SKU fall through to `No Match` instead of getting a vector score. The `Pending Review` human review path is unreachable until this is resolved.

---

### `RecalculateSubmissionPoints.cls`
Invocable Apex called by the reviewer flow after a human approves or rejects items.

Recalculates `Total_Points_Awarded__c` by summing all `Is_Eligible__c = true` line items. Sets `Status__c` back to `Under Review` if any items remain in `Pending Review`, or to `Approved` / `Under Review` based on whether points > 0.

---

## Flows

### `Invoice_Loyalty_Submission` (Screen Flow)
Customer-facing flow embedded in the Experience Cloud portal.

| Step | What happens |
|---|---|
| Screen: Upload Invoice | Customer sees instructions + file upload button |
| Apex: DocumentAIService | Sends PDF to DocumentAI, gets raw JSON |
| Decision: Extraction OK? | Routes to error screen on failure |
| Apex: InvoiceLoyaltyProcessor | Parses JSON, creates records, matches products |
| Decision: Duplicate? | Routes to "already submitted" warning screen |
| Decision: Success? | Routes to confirmation or error screen |
| Screen: Confirmation | Shows total points awarded |
| Screen: Duplicate | Amber warning — invoice was already submitted |
| Screen: Error | Shows technical error message |

### `Invoice_Line_Item_Review` (Screen Flow — internal)
Internal reviewer flow for approving/rejecting `Pending Review` line items.

**Input variable:** `varSubmissionId` (String) — passed when launching from the submission record button.

| Step | What happens |
|---|---|
| Get Pending Items | Queries all `Pending Review` line items for the submission |
| Decision: Any pending? | Routes to "nothing to review" screen if none |
| Loop: each item | Shows Description, Reference (SKU), Suggested Product, Similarity Score, Unit Price × Qty |
| Screen: Review Item | Radio buttons: Approve / Reject |
| Decision: Approved? | Routes to update record |
| Record Update: Approved | Sets `Match_Status__c = Approved by Reviewer`, `Is_Eligible__c = true`, calculates points |
| Record Update: Rejected | Sets `Match_Status__c = Rejected by Reviewer`, `Is_Eligible__c = false`, points = 0 |
| Apex: RecalculateSubmissionPoints | Recalculates total points and submission status |
| Screen: Review Complete | Shows total points that will be awarded |

---

## Data Cloud setup

### Named Credential: `Data_Cloud_API`
All callouts use `callout:Data_Cloud_API` as the base. Configure in **Setup → Named Credentials**:
- URL: `https://<your-dc-tenant>.c360a.salesforce.com`
- Auth: OAuth 2.0 via the Data Cloud Connected App

### DocumentAI configuration: `Intuis_Invoice_Extraction`
DocumentAI schema set up in Data Cloud to extract:
- `invoice_number`, `invoice_date`, `supplier_name`
- `total_amount_ht` / `total_ht`
- `items` array with per-line: `reference`, `description`, `quantity`, `net_unit_price_ht` / `unit_price_ht` / `total_price_ht`

### Data Cloud DMO: `ssot__Product__dlm`
Populated via the Salesforce CRM connector — syncs `Product2` records into Data Cloud. Fields used:
- `ssot__Id__c` — maps back to `Product2.Id`
- `ssot__Name__c` — product name
- `ssot__ProductCode__c` — SKU

### Search Index: `Product_index`
- **Developer name:** `Product_index`
- **Source DMO:** `ssot__Product__dlm`
- **Field indexed:** `ssot__Name__c` (product name)
- **Embedding model:** `e5_large_v2`
- **Search type:** HYBRID
- **Runtime status:** READY
- **Chunk DMO:** `Product_index_chunk__dlm`
- **Vector DMO:** `Product_index_index__dlm`

> **Note:** The index is built and populated, but runtime `HYBRID_SEARCH` queries fail org-wide. See `DataCloudVectorSearch.cls` notes above.

---

## Setup checklist

### 1. Populate Product2 records
Ensure your eligible products have `IsActive = true` and a non-blank `ProductCode` (SKU). These ProductCodes are what the invoice `reference` field is matched against.

### 2. Configure the Named Credential
**Setup → Named Credentials → Data_Cloud_API**
- URL: your Data Cloud tenant URL
- OAuth 2.0 with the Data Cloud Connected App

### 3. Verify the DocumentAI configuration
**Data Cloud → Document AI → Intuis_Invoice_Extraction** must be active and trained on invoice PDFs of the expected format.

### 4. Add the Flow to Experience Cloud
1. Experience Builder → your portal page
2. Drag **Flow** component
3. Select `Invoice Loyalty Submission`
4. Publish

### 5. Add the reviewer button to Invoice Submission layout
A **Quick Action** on `Invoice_Submission__c` should launch `Invoice_Line_Item_Review` with `{!Record.Id}` mapped to `varSubmissionId`. Add it to the page layout or Lightning page so internal staff can start the review.

### 6. Field-level security
The Admin profile has full access. For Experience Cloud users, ensure they have at minimum:
- Read/Write on `Invoice_Submission__c` and `Invoice_Line_Item__c`
- Apex class access: `DocumentAIService`, `InvoiceLoyaltyProcessor`
- Flow access: `Invoice_Loyalty_Submission`

---

## Deploying

```bash
# Deploy everything
sf project deploy start --source-dir force-app -o mlegelard1234@salesforce.com

# Deploy only Apex
sf project deploy start --source-dir force-app/main/default/classes -o mlegelard1234@salesforce.com

# Deploy a single class
sf project deploy start --source-dir force-app/main/default/classes/InvoiceLoyaltyProcessor.cls -o mlegelard1234@salesforce.com

# Deploy a single flow
sf project deploy start --source-dir force-app/main/default/flows -o mlegelard1234@salesforce.com
```

---

## Project structure

```
invoice-loyalty-demo/
├── sfdx-project.json
├── Salesforce Data 360 APIs.postman_collection.json        ← Legacy DC API collection
├── Salesforce Data 360 Connect APIs.postman_collection.json ← Current DC API collection
└── force-app/main/default/
    ├── classes/
    │   ├── DocumentAIService.cls               ← DocumentAI callout
    │   ├── DataCloudAssetService.cls           ← Product2 catalog loader + SKU lookup
    │   ├── DataCloudVectorSearch.cls           ← Data Cloud hybrid search (blocked, see notes)
    │   ├── InvoiceLoyaltyProcessor.cls         ← Main processor: parse → match → create records
    │   └── RecalculateSubmissionPoints.cls     ← Post-review point recalculation
    ├── flows/
    │   ├── Invoice_Loyalty_Submission.flow-meta.xml    ← Customer-facing upload flow
    │   └── Invoice_Line_Item_Review.flow-meta.xml      ← Internal reviewer flow
    ├── objects/
    │   ├── Invoice_Submission__c/              ← Parent record per invoice
    │   ├── Invoice_Line_Item__c/               ← One record per extracted line item
    ├── layouts/
    │   ├── Invoice_Submission__c-Invoice Submission Layout.layout-meta.xml
    │   └── Invoice_Line_Item__c-Invoice Line Item Layout.layout-meta.xml
    └── profiles/
        └── Admin.profile-meta.xml
```

---

