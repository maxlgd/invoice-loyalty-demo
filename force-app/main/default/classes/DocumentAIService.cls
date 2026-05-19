public with sharing class DocumentAIService {

    @InvocableMethod(label='Extract Invoice with DocumentAI' description='Sends uploaded PDF to Data Cloud DocumentAI and returns extracted JSON')
    public static List<ExtractionResult> extractInvoice(List<ExtractionRequest> requests) {
        List<ExtractionResult> results = new List<ExtractionResult>();
        for (ExtractionRequest req : requests) {
            results.add(doExtract(req.contentDocumentId));
        }
        return results;
    }

    private static ExtractionResult doExtract(String contentDocumentId) {
        ExtractionResult result = new ExtractionResult();
        try {
            ContentVersion cv = [
                SELECT VersionData, FileType
                FROM ContentVersion
                WHERE ContentDocumentId = :contentDocumentId
                AND IsLatest = true
                LIMIT 1
            ];

            // API expects JSON body with file as base64
            String base64Data = EncodingUtil.base64Encode(cv.VersionData);
            Map<String, String> mimeMap = new Map<String, String>{
                'PDF'  => 'application/pdf',
                'PNG'  => 'image/png',
                'JPG'  => 'image/jpeg',
                'JPEG' => 'image/jpeg',
                'TIFF' => 'image/tiff',
                'BMP'  => 'image/bmp'
            };
            String mimeType = mimeMap.containsKey(cv.FileType.toUpperCase())
                ? mimeMap.get(cv.FileType.toUpperCase())
                : 'application/octet-stream';

            Map<String, Object> requestBody = new Map<String, Object>{
                'idpConfigurationIdOrName' => 'Intuis_Invoice_Extraction',
                'files' => new List<Object>{
                    new Map<String, Object>{
                        'mimeType' => mimeType,
                        'data' => base64Data
                    }
                }
            };

            String endpoint = 'callout:Data_Cloud_API/services/data/v63.0/ssot/document-processing/actions/extract-data';

            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            req.setBody(JSON.serialize(requestBody));
            req.setTimeout(120000);

            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
                result.rawJson = res.getBody();
                result.success = true;
            } else {
                result.success = false;
                result.errorMessage = 'DocumentAI returned HTTP ' + res.getStatusCode() + ': ' + res.getBody().left(500);
            }
        } catch (Exception e) {
            result.success = false;
            result.errorMessage = e.getTypeName() + ': ' + e.getMessage();
        }
        return result;
    }

    public class ExtractionRequest {
        @InvocableVariable(label='Content Document Id' required=true)
        public String contentDocumentId;
    }

    public class ExtractionResult {
        @InvocableVariable(label='Raw JSON from DocumentAI')
        public String rawJson;

        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }
}
