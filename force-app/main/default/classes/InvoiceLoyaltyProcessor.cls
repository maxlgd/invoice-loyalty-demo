public with sharing class InvoiceLoyaltyProcessor {

    @InvocableMethod(label='Process Invoice Extraction' description='Creates invoice records from DocumentAI JSON and awards loyalty points')
    public static List<InvoiceResult> processInvoice(List<InvoiceRequest> requests) {
        List<InvoiceResult> results = new List<InvoiceResult>();
        for (InvoiceRequest req : requests) {
            results.add(process(req));
        }
        return results;
    }

    private static InvoiceResult process(InvoiceRequest req) {
        InvoiceResult result = new InvoiceResult();
        try {
            // Parse DocumentAI response
            // Outer: { "data": [ { "data": "<html-escaped JSON>" } ] }
            Map<String, Object> outerMap = (Map<String, Object>) JSON.deserializeUntyped(req.rawJson);
            List<Object> dataArray = (List<Object>) outerMap.get('data');
            Map<String, Object> firstEntry = (Map<String, Object>) dataArray[0];
            String innerRaw = (String) firstEntry.get('data');
            innerRaw = innerRaw.replace('&quot;', '"').replace('&amp;', '&').replace('&lt;', '<')
                               .replace('&gt;', '>').replace('&#39;', '\'').replace('&#92;n', ' ').replace('&#92;', '\\');
            Map<String, Object> innerMap = (Map<String, Object>) JSON.deserializeUntyped(innerRaw);

            String invoiceNumber  = getStringValue(innerMap, 'invoice_number');
            String supplierName   = getStringValue(innerMap, 'supplier_name');
            Decimal totalAmountHt = getTotalAmountHt(innerMap);

            // ── STEP 1: Duplicate check ──────────────────────────────────────
            String fingerprint = buildFingerprint(invoiceNumber, supplierName, totalAmountHt);
            if (![SELECT Id FROM Invoice_Submission__c WHERE Duplicate_Fingerprint__c = :fingerprint LIMIT 1].isEmpty()) {
                result.success      = false;
                result.isDuplicate  = true;
                result.errorMessage = 'This invoice has already been submitted (invoice number: ' + invoiceNumber + ').';
                return result;
            }

            // ── STEP 2: Load SKU catalog (SOQL — before any DML) ────────────
            Map<String, DataCloudAssetService.EligibleAssetRecord> catalogByCode = DataCloudAssetService.loadCatalogByCode();

            // ── STEP 3: Parse line items and resolve each against the catalog ─
            List<Object> rawItems = new List<Object>();
            Map<String, Object> itemsField = (Map<String, Object>) innerMap.get('items');
            if (itemsField != null) rawItems = (List<Object>) itemsField.get('value');

            List<Invoice_Line_Item__c> lineRecords = new List<Invoice_Line_Item__c>();
            Integer totalPoints = 0;

            // Resolve all items before any DML
            List<Map<String, Object>> resolvedItems = new List<Map<String, Object>>();
            List<String> matchStatuses = new List<String>();
            List<Boolean> eligibleFlags = new List<Boolean>();
            List<String> productIds = new List<String>();

            for (Object itemObj : rawItems) {
                Map<String, Object> item   = (Map<String, Object>) itemObj;
                Map<String, Object> fields = (Map<String, Object>) item.get('value');
                if (fields == null) {
                    resolvedItems.add(null);
                    matchStatuses.add(null);
                    eligibleFlags.add(false);
                    productIds.add(null);
                    continue;
                }

                String itemRef = getStringValue(fields, 'reference');
                DataCloudAssetService.AssetMatch skuMatch = DataCloudAssetService.findByProductCode(itemRef, catalogByCode);

                resolvedItems.add(fields);
                if (skuMatch != null) {
                    matchStatuses.add('SKU Match');
                    eligibleFlags.add(true);
                    productIds.add(skuMatch.assetId);
                } else {
                    matchStatuses.add('No Match');
                    eligibleFlags.add(false);
                    productIds.add(null);
                }
            }

            // ── STEP 4: All DML from here ────────────────────────────────────
            String contactId = req.contactId;
            if (String.isBlank(contactId)) {
                User u = [SELECT ContactId FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
                contactId = u.ContactId;
            }

            Invoice_Submission__c submission = new Invoice_Submission__c();
            submission.Contact__c               = contactId;
            submission.Raw_JSON__c              = JSON.serializePretty(innerMap);
            submission.Content_Document_Id__c   = req.contentDocumentId;
            submission.Status__c                = 'Pending';
            submission.Duplicate_Fingerprint__c = fingerprint;
            if (invoiceNumber != null) submission.Invoice_Number__c = invoiceNumber.left(80);
            if (supplierName  != null) submission.Supplier_Name__c  = supplierName.left(255);
            if (totalAmountHt != null) submission.Total_Amount_HT__c = totalAmountHt;

            String invoiceDate = getStringValue(innerMap, 'invoice_date');
            if (invoiceDate != null) {
                try { submission.Invoice_Date__c = parseDate(invoiceDate); } catch (Exception e) {}
            }
            insert submission;

            if (String.isNotBlank(req.contentDocumentId)) {
                try {
                    insert new ContentDocumentLink(
                        ContentDocumentId = req.contentDocumentId,
                        LinkedEntityId    = submission.Id,
                        ShareType         = 'V',
                        Visibility        = 'AllUsers'
                    );
                } catch (Exception e) { /* already linked */ }
            }

            for (Integer i = 0; i < resolvedItems.size(); i++) {
                Map<String, Object> fields = resolvedItems[i];
                if (fields == null) continue;

                Invoice_Line_Item__c lineRec = new Invoice_Line_Item__c();
                lineRec.Invoice_Submission__c = submission.Id;

                String itemDesc = getStringValue(fields, 'description');
                lineRec.Product_Description__c = itemDesc != null ? itemDesc.left(255) : 'Unknown';

                String itemRef = getStringValue(fields, 'reference');
                if (itemRef != null) lineRec.Reference__c = itemRef.left(100);

                Object qtyVal = getTypedValue(fields, 'quantity');
                lineRec.Quantity__c = qtyVal != null ? Decimal.valueOf(String.valueOf(qtyVal)) : 1;

                Object priceVal = getTypedValue(fields, 'net_unit_price_ht');
                if (priceVal == null) priceVal = getTypedValue(fields, 'unit_price_ht');
                if (priceVal == null) priceVal = getTypedValue(fields, 'total_price_ht');
                lineRec.Unit_Price__c = priceVal != null ? Decimal.valueOf(String.valueOf(priceVal)) : 0;

                lineRec.Match_Status__c = matchStatuses[i];
                lineRec.Is_Eligible__c  = eligibleFlags[i];

                if (productIds[i] != null) {
                    lineRec.Matched_Product_Id__c = productIds[i];
                }

                if (eligibleFlags[i]) {
                    Integer pts = Integer.valueOf((lineRec.Unit_Price__c * lineRec.Quantity__c).setScale(0, RoundingMode.HALF_UP));
                    lineRec.Points_Awarded__c = pts;
                    totalPoints += pts;
                } else {
                    lineRec.Points_Awarded__c = 0;
                }

                lineRecords.add(lineRec);
            }

            if (!lineRecords.isEmpty()) insert lineRecords;

            submission.Total_Points_Awarded__c = totalPoints;
            submission.Status__c = totalPoints > 0 ? 'Approved' : 'Under Review';
            update submission;

            result.submissionId = submission.Id;
            result.totalPoints  = totalPoints;
            result.success      = true;
            result.isDuplicate  = false;

        } catch (Exception e) {
            result.success      = false;
            result.isDuplicate  = false;
            result.errorMessage = e.getTypeName() + ' at line ' + e.getLineNumber() + ': ' + e.getMessage();
        }
        return result;
    }

    private static String buildFingerprint(String invoiceNumber, String supplierName, Decimal totalHt) {
        String num      = String.isBlank(invoiceNumber) ? '' : invoiceNumber.trim().toUpperCase();
        String supplier = String.isBlank(supplierName)  ? '' : supplierName.trim().toUpperCase().replaceAll('[^A-Z0-9]', '');
        String amount   = totalHt != null ? String.valueOf(totalHt.setScale(2)) : '0.00';
        Blob hash = Crypto.generateDigest('SHA-256', Blob.valueOf(num + '|' + supplier + '|' + amount));
        return EncodingUtil.convertToHex(hash);
    }

    private static Decimal getTotalAmountHt(Map<String, Object> innerMap) {
        Object topLevel = getTypedValue(innerMap, 'total_amount_ht');
        if (topLevel == null) topLevel = getTypedValue(innerMap, 'total_ht');
        if (topLevel != null) {
            try { return Decimal.valueOf(String.valueOf(topLevel)); } catch (Exception e) {}
        }
        Decimal total = 0;
        Map<String, Object> itemsField = (Map<String, Object>) innerMap.get('items');
        if (itemsField != null) {
            for (Object itemObj : (List<Object>) itemsField.get('value')) {
                Map<String, Object> item   = (Map<String, Object>) itemObj;
                Map<String, Object> fields = (Map<String, Object>) item.get('value');
                if (fields == null) continue;
                Object price = getTypedValue(fields, 'total_price_ht');
                if (price == null) price = getTypedValue(fields, 'net_unit_price_ht');
                if (price != null) { try { total += Decimal.valueOf(String.valueOf(price)); } catch (Exception e) {} }
            }
        }
        return total;
    }

    private static String getStringValue(Map<String, Object> m, String key) {
        if (!m.containsKey(key)) return null;
        Map<String, Object> field = (Map<String, Object>) m.get(key);
        Object val = field.get('value');
        return val != null ? String.valueOf(val) : null;
    }

    private static Object getTypedValue(Map<String, Object> m, String key) {
        if (!m.containsKey(key)) return null;
        Map<String, Object> field = (Map<String, Object>) m.get(key);
        return field.get('value');
    }

    private static Date parseDate(String s) {
        if (s.contains('/')) {
            List<String> parts = s.split('/');
            if (parts.size() == 3) {
                Integer yr = Integer.valueOf(parts[2]);
                if (yr < 100) yr += 2000;
                return Date.newInstance(yr, Integer.valueOf(parts[1]), Integer.valueOf(parts[0]));
            }
        }
        return Date.valueOf(s);
    }

    public class InvoiceRequest {
        @InvocableVariable(label='Raw JSON from DocumentAI' required=true)
        public String rawJson;
        @InvocableVariable(label='ContentDocument Id of uploaded file' required=true)
        public String contentDocumentId;
        @InvocableVariable(label='Contact Id (optional, defaults to running user)')
        public String contactId;
    }

    public class InvoiceResult {
        @InvocableVariable(label='Invoice Submission Record Id')
        public String submissionId;
        @InvocableVariable(label='Total Points Awarded')
        public Integer totalPoints;
        @InvocableVariable(label='Success')
        public Boolean success;
        @InvocableVariable(label='Is Duplicate')
        public Boolean isDuplicate;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }
}
