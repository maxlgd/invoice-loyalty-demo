public with sharing class DataCloudAssetService {

    public class AssetMatch {
        public String assetId;
        public String assetName;
        public String productCode;
    }

    // Exact match on ProductCode (case-insensitive).
    public static AssetMatch findByProductCode(String reference, Map<String, EligibleAssetRecord> catalogByCode) {
        if (String.isBlank(reference) || catalogByCode.isEmpty()) return null;
        EligibleAssetRecord found = catalogByCode.get(reference.trim().toUpperCase());
        if (found == null) return null;
        AssetMatch m = new AssetMatch();
        m.assetId     = found.id;
        m.assetName   = found.name;
        m.productCode = found.productCode;
        return m;
    }

    // Returns a map of UPPERCASE ProductCode → EligibleAssetRecord for O(1) lookups.
    public static Map<String, EligibleAssetRecord> loadCatalogByCode() {
        Map<String, EligibleAssetRecord> byCode = new Map<String, EligibleAssetRecord>();
        for (Product2 p : [SELECT Id, Name, ProductCode FROM Product2 WHERE IsActive = true AND ProductCode != null]) {
            EligibleAssetRecord r = new EligibleAssetRecord();
            r.id          = p.Id;
            r.name        = p.Name;
            r.productCode = p.ProductCode;
            byCode.put(p.ProductCode.toUpperCase(), r);
        }
        return byCode;
    }

    public class EligibleAssetRecord {
        public String id;
        public String name;
        public String productCode;
    }
}
