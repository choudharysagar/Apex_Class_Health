/**
 * Backs the apexClassHealth LWC with every unmanaged Apex class, its size, code coverage and quality grade, and lets
 * team members run tests and see which classes they cover.
 * Runs without sharing in system mode so every team member sees all classes; only metrics leave the server, never source.
 * Coverage comes from the Tooling API, called with the running user's own API session (the org's My Domain URL must be
 * in Remote Site Settings); if that call fails the classes are still returned and graded on API version and size only.
 */
public without sharing class ApexClassHealthController {
    private static final String TOOLING_QUERY_PATH = '/services/data/v66.0/tooling/query/?q=';
    // Must match the markers around the session ID in the ApexClassHealthSession Visualforce page.
    private static final String SESSION_ID_START = 'SESSION_ID_START';
    private static final String SESSION_ID_END = 'SESSION_ID_END';
    private static final String AGGREGATE_COVERAGE_QUERY =
        'SELECT ApexClassOrTriggerId, NumLinesCovered, NumLinesUncovered FROM ApexCodeCoverageAggregate';
    private static final Integer CALLOUT_TIMEOUT_MS = 60000;
    private static final String GRADE_FALLBACK_NOTE = 'Grades reflect API version and class size only.';
    private static final Set<String> FINISHED_QUEUE_STATUSES = new Set<String>{ 'Completed', 'Failed', 'Aborted' };

    private static final List<String> GRADES = new List<String>{ 'A', 'B', 'C', 'D' };
    private static final Decimal TARGET_COVERAGE = 90;
    private static final Decimal REQUIRED_COVERAGE = 75;
    private static final Decimal LOW_COVERAGE = 50;
    // Salesforce ships three releases a year, so nine versions behind is roughly three years old.
    private static final Decimal MAX_API_VERSIONS_BEHIND = 9;
    private static final Integer MAX_LINES_OF_CODE = 1000;

    private static String apiSessionId;

    @AuraEnabled(cacheable=true)
    public static HealthReport getApexClassHealth() {
        try {
            HealthReport report = new HealthReport();
            Map<Id, ToolingRecord> coverageByClassId = new Map<Id, ToolingRecord>();
            try {
                coverageByClassId = fetchCoverage();
                report.coverageAvailable = !coverageByClassId.isEmpty();
                if (!report.coverageAvailable) {
                    report.coverageMessage =
                        'No code coverage data was found. Run your Apex tests to calculate it. ' + GRADE_FALLBACK_NOTE;
                }
            } catch (Exception e) {
                // Coverage is optional, so a Tooling API failure must not block the class list.
                report.coverageMessage =
                    'Code coverage is unavailable (' + e.getMessage() + '). ' + GRADE_FALLBACK_NOTE;
            }

            Decimal latestApiVersion = 0;
            // The list form of the SOQL for loop releases class bodies from the heap after each 200-record chunk.
            for (List<ApexClass> apexClasses : [
                SELECT Id, Name, ApiVersion, Body, LengthWithoutComments, LastModifiedDate, LastModifiedBy.Name
                FROM ApexClass
                WHERE NamespacePrefix = NULL
                WITH SYSTEM_MODE
                ORDER BY Name
            ]) {
                for (ApexClass apexClass : apexClasses) {
                    ClassHealth item = toClassHealth(apexClass, coverageByClassId.get(apexClass.Id));
                    latestApiVersion = Math.max(latestApiVersion, item.apiVersion);
                    report.classes.add(item);
                }
            }

            // Setup's "Percent of Apex Used" counts triggers as well as classes.
            for (ApexTrigger apexTrigger : [
                SELECT LengthWithoutComments
                FROM ApexTrigger
                WHERE NamespacePrefix = NULL
                WITH SYSTEM_MODE
            ]) {
                report.triggerCharacters += apexTrigger.LengthWithoutComments;
            }

            for (ClassHealth item : report.classes) {
                applyGrade(item, report.coverageAvailable, latestApiVersion);
            }
            return report;
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /**
     * Queues the selected test classes, plus the test classes that already cover any selected non-test class.
     */
    @AuraEnabled
    public static TestRun runTests(List<Id> classIds) {
        try {
            TestRun run = planTestRun(classIds);
            List<ApexTestQueueItem> queueItems = new List<ApexTestQueueItem>();
            for (Id testClassId : run.testClassIds) {
                queueItems.add(new ApexTestQueueItem(ApexClassId = testClassId));
            }
            // Items inserted together share one parent job.
            insert as system queueItems;
            ApexTestQueueItem firstItem = [
                SELECT ParentJobId
                FROM ApexTestQueueItem
                WHERE Id = :queueItems[0].Id
                WITH SYSTEM_MODE
            ];
            run.jobId = firstItem.ParentJobId;
            return run;
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    // Kept apart from runTests because Apex tests can't enqueue other tests.
    @TestVisible
    private static TestRun planTestRun(List<Id> classIds) {
        Set<Id> testClassIds = new Set<Id>();
        Map<Id, String> otherClassNames = new Map<Id, String>();
        for (List<ApexClass> apexClasses : [
            SELECT Id, Name, Body
            FROM ApexClass
            WHERE Id IN :classIds
            WITH SYSTEM_MODE
        ]) {
            for (ApexClass apexClass : apexClasses) {
                if (isTestClass(apexClass.Body)) {
                    testClassIds.add(apexClass.Id);
                } else {
                    otherClassNames.put(apexClass.Id, apexClass.Name);
                }
            }
        }

        TestRun run = new TestRun();
        if (!otherClassNames.isEmpty()) {
            Set<Id> coveredClassIds = new Set<Id>();
            for (ToolingRecord row : queryTooling(
                'SELECT ApexTestClassId, ApexClassOrTriggerId FROM ApexCodeCoverage WHERE ApexClassOrTriggerId IN ' +
                toSoqlList(otherClassNames.keySet())
            )) {
                testClassIds.add(row.apexTestClassId);
                coveredClassIds.add(row.apexClassOrTriggerId);
            }
            for (Id classId : otherClassNames.keySet()) {
                if (!coveredClassIds.contains(classId)) {
                    run.classesWithoutTests.add(otherClassNames.get(classId));
                }
            }
        }
        if (testClassIds.isEmpty()) {
            throw new ApexClassHealthException(
                'No tests found for the selected classes. Select test classes, or run the tests that cover ' +
                'these classes once from Setup so they can be found.'
            );
        }
        run.testClassIds = new List<Id>(testClassIds);
        return run;
    }

    @AuraEnabled
    public static TestRunStatus getTestRunStatus(Id jobId) {
        try {
            TestRunStatus status = new TestRunStatus();
            for (ApexTestQueueItem item : [
                SELECT Status
                FROM ApexTestQueueItem
                WHERE ParentJobId = :jobId
                WITH SYSTEM_MODE
            ]) {
                status.classesTotal++;
                if (FINISHED_QUEUE_STATUSES.contains(item.Status)) {
                    status.classesCompleted++;
                }
            }
            status.isComplete = status.classesCompleted == status.classesTotal;
            if (!status.isComplete) {
                return status;
            }

            for (ApexTestResult result : [
                SELECT Outcome, MethodName, Message, ApexClass.Name
                FROM ApexTestResult
                WHERE AsyncApexJobId = :jobId
                WITH SYSTEM_MODE
                ORDER BY ApexClass.Name, MethodName
            ]) {
                if (result.Outcome == 'Pass') {
                    status.methodsPassed++;
                } else if (result.Outcome != 'Skip') {
                    TestFailure failure = new TestFailure();
                    failure.className = result.ApexClass.Name;
                    failure.methodName = result.MethodName;
                    failure.message = result.Message;
                    status.failures.add(failure);
                }
            }
            return status;
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /**
     * Lists the classes and triggers the given test classes exercise, with each one's overall coverage.
     */
    @AuraEnabled
    public static List<CoverageItem> getClassesCoveredByTests(List<Id> testClassIds) {
        try {
            Map<Id, String> namesById = new Map<Id, String>();
            for (ToolingRecord row : queryTooling(
                'SELECT ApexClassOrTriggerId, ApexClassOrTrigger.Name FROM ApexCodeCoverage WHERE ApexTestClassId IN ' +
                toSoqlList(new Set<Id>(testClassIds))
            )) {
                namesById.put(row.apexClassOrTriggerId, row.apexClassOrTrigger?.name);
            }

            List<CoverageItem> items = new List<CoverageItem>();
            Map<Id, ToolingRecord> aggregates = namesById.isEmpty() ? new Map<Id, ToolingRecord>() : fetchCoverage();
            for (Id classId : namesById.keySet()) {
                ToolingRecord aggregate = aggregates.get(classId);
                items.add(
                    toCoverageItem(
                        classId,
                        namesById.get(classId),
                        aggregate?.numLinesCovered,
                        aggregate == null ? null : aggregate.numLinesCovered + aggregate.numLinesUncovered
                    )
                );
            }
            items.sort();
            return items;
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    /**
     * Lists the test classes that cover the given class, with the share of its lines each one covers.
     */
    @AuraEnabled
    public static List<CoverageItem> getTestsCoveringClass(Id classId) {
        try {
            Map<Id, String> testClassNames = new Map<Id, String>();
            Map<Id, Set<Integer>> coveredLinesByTestClassId = new Map<Id, Set<Integer>>();
            Integer executableLines = 0;
            for (ToolingRecord row : queryTooling(
                'SELECT ApexTestClassId, ApexTestClass.Name, Coverage FROM ApexCodeCoverage ' +
                'WHERE ApexClassOrTriggerId = \'' + classId + '\''
            )) {
                if (!coveredLinesByTestClassId.containsKey(row.apexTestClassId)) {
                    testClassNames.put(row.apexTestClassId, row.apexTestClass?.name);
                    coveredLinesByTestClassId.put(row.apexTestClassId, new Set<Integer>());
                }
                // One row per test method; methods overlap, so union their lines instead of summing counts.
                coveredLinesByTestClassId.get(row.apexTestClassId).addAll(row.coverage.coveredLines);
                executableLines = Math.max(
                    executableLines,
                    row.coverage.coveredLines.size() + row.coverage.uncoveredLines.size()
                );
            }

            List<CoverageItem> items = new List<CoverageItem>();
            for (Id testClassId : testClassNames.keySet()) {
                items.add(
                    toCoverageItem(
                        testClassId,
                        testClassNames.get(testClassId),
                        coveredLinesByTestClassId.get(testClassId).size(),
                        executableLines
                    )
                );
            }
            items.sort();
            return items;
        } catch (Exception e) {
            throw toAuraException(e);
        }
    }

    @TestVisible
    private static void applyGrade(ClassHealth item, Boolean coverageAvailable, Decimal latestApiVersion) {
        List<String> findings = new List<String>();
        Integer gradeIndex = 0;
        if (coverageAvailable && !item.isTest) {
            if (item.coverage == null) {
                gradeIndex = 3;
                findings.add('No coverage data');
            } else if (item.coverage < LOW_COVERAGE) {
                gradeIndex = 3;
                findings.add('Coverage below ' + LOW_COVERAGE + '%');
            } else if (item.coverage < REQUIRED_COVERAGE) {
                gradeIndex = 2;
                findings.add('Coverage below ' + REQUIRED_COVERAGE + '%');
            } else if (item.coverage < TARGET_COVERAGE) {
                gradeIndex = 1;
                findings.add('Coverage below ' + TARGET_COVERAGE + '%');
            }
        }
        if (item.apiVersion < latestApiVersion - MAX_API_VERSIONS_BEHIND) {
            gradeIndex++;
            findings.add('API version more than 3 years old');
        }
        if (item.linesOfCode > MAX_LINES_OF_CODE) {
            gradeIndex++;
            findings.add('More than ' + MAX_LINES_OF_CODE + ' lines');
        }
        item.grade = GRADES[Math.min(gradeIndex, GRADES.size() - 1)];
        item.findings = String.join(findings, '; ');
    }

    private static ClassHealth toClassHealth(ApexClass apexClass, ToolingRecord coverage) {
        String body = apexClass.Body == null ? '' : apexClass.Body;
        Integer lineBreaks = body.countMatches('\n');

        ClassHealth item = new ClassHealth();
        item.id = apexClass.Id;
        item.name = apexClass.Name;
        item.apiVersion = apexClass.ApiVersion;
        item.characters = apexClass.LengthWithoutComments;
        item.linesOfCode = body.endsWith('\n') ? lineBreaks : lineBreaks + 1;
        item.isTest = isTestClass(body);
        item.lastModifiedDate = apexClass.LastModifiedDate;
        item.lastModifiedBy = apexClass.LastModifiedBy?.Name;

        Integer executableLines = coverage == null ? 0 : coverage.numLinesCovered + coverage.numLinesUncovered;
        if (!item.isTest && executableLines > 0) {
            item.linesCovered = coverage.numLinesCovered;
            item.linesUncovered = coverage.numLinesUncovered;
            item.coverage = percent(coverage.numLinesCovered, executableLines);
        }
        return item;
    }

    private static CoverageItem toCoverageItem(Id id, String name, Integer linesCovered, Integer linesTotal) {
        CoverageItem item = new CoverageItem();
        item.id = id;
        item.name = name;
        item.linesCovered = linesCovered;
        item.linesTotal = linesTotal;
        if (linesTotal != null && linesTotal > 0) {
            item.coverage = percent(linesCovered, linesTotal);
        }
        return item;
    }

    private static Boolean isTestClass(String body) {
        return body != null && body.containsIgnoreCase('@isTest');
    }

    private static Decimal percent(Integer covered, Integer total) {
        Decimal coveredLines = covered;
        return (coveredLines * 100).divide(total, 2);
    }

    private static Map<Id, ToolingRecord> fetchCoverage() {
        Map<Id, ToolingRecord> coverageByClassId = new Map<Id, ToolingRecord>();
        for (ToolingRecord row : queryTooling(AGGREGATE_COVERAGE_QUERY)) {
            coverageByClassId.put(row.apexClassOrTriggerId, row);
        }
        return coverageByClassId;
    }

    private static List<ToolingRecord> queryTooling(String soql) {
        List<ToolingRecord> rows = new List<ToolingRecord>();
        String path = TOOLING_QUERY_PATH + EncodingUtil.urlEncode(soql, 'UTF-8');
        // Stop paging before the callout limit, which would otherwise throw an uncatchable LimitException.
        while (path != null && Limits.getCallouts() < Limits.getLimitCallouts()) {
            HttpRequest request = new HttpRequest();
            request.setEndpoint(URL.getOrgDomainUrl().toExternalForm() + path);
            request.setMethod('GET');
            request.setHeader('Accept', 'application/json');
            request.setHeader('Authorization', 'Bearer ' + getApiSessionId());
            request.setTimeout(CALLOUT_TIMEOUT_MS);

            HttpResponse response = new Http().send(request);
            if (response.getStatusCode() != 200) {
                throw new ApexClassHealthException(
                    'Tooling API responded with ' + response.getStatusCode() + ' ' + response.getStatus()
                );
            }

            ToolingQueryResult page = (ToolingQueryResult) JSON.deserialize(
                response.getBody(),
                ToolingQueryResult.class
            );
            rows.addAll(page.records);
            path = page.done ? null : page.nextRecordsUrl;
        }
        return rows;
    }

    // Lightning sessions can't call the REST API, but the session a Visualforce page renders can.
    private static String getApiSessionId() {
        // getContent() isn't allowed in Apex tests, where every callout is mocked anyway.
        if (apiSessionId == null && !Test.isRunningTest()) {
            String content = Page.ApexClassHealthSession.getContent().toString();
            apiSessionId = content.substringBetween(SESSION_ID_START, SESSION_ID_END);
        }
        return apiSessionId;
    }

    // Ids are typed, so they can't carry SOQL injection into the Tooling query.
    private static String toSoqlList(Set<Id> ids) {
        return '(\'' + String.join(new List<Id>(ids), '\',\'') + '\')';
    }

    private static AuraHandledException toAuraException(Exception e) {
        AuraHandledException auraException = new AuraHandledException(e.getMessage());
        // Without setMessage, getMessage() returns "Script-thrown exception" in Apex tests.
        auraException.setMessage(e.getMessage());
        return auraException;
    }

    public class HealthReport {
        @AuraEnabled
        public List<ClassHealth> classes = new List<ClassHealth>();
        @AuraEnabled
        public Boolean coverageAvailable = false;
        @AuraEnabled
        public String coverageMessage;
        @AuraEnabled
        public Integer triggerCharacters = 0;
    }

    public class ClassHealth {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public Boolean isTest;
        @AuraEnabled
        public Decimal apiVersion;
        @AuraEnabled
        public Integer linesOfCode;
        @AuraEnabled
        public Integer characters;
        @AuraEnabled
        public Integer linesCovered;
        @AuraEnabled
        public Integer linesUncovered;
        @AuraEnabled
        public Decimal coverage;
        @AuraEnabled
        public String grade;
        @AuraEnabled
        public String findings;
        @AuraEnabled
        public Datetime lastModifiedDate;
        @AuraEnabled
        public String lastModifiedBy;
    }

    public class TestRun {
        @AuraEnabled
        public Id jobId;
        @AuraEnabled
        public List<Id> testClassIds = new List<Id>();
        @AuraEnabled
        public List<String> classesWithoutTests = new List<String>();
    }

    public class TestRunStatus {
        @AuraEnabled
        public Boolean isComplete = false;
        @AuraEnabled
        public Integer classesTotal = 0;
        @AuraEnabled
        public Integer classesCompleted = 0;
        @AuraEnabled
        public Integer methodsPassed = 0;
        @AuraEnabled
        public List<TestFailure> failures = new List<TestFailure>();
    }

    public class TestFailure {
        @AuraEnabled
        public String className;
        @AuraEnabled
        public String methodName;
        @AuraEnabled
        public String message;
    }

    public class CoverageItem implements Comparable {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public Integer linesCovered;
        @AuraEnabled
        public Integer linesTotal;
        @AuraEnabled
        public Decimal coverage;

        public Integer compareTo(Object other) {
            return String.valueOf(name).compareTo(String.valueOf(((CoverageItem) other).name));
        }
    }

    private class ToolingQueryResult {
        public Boolean done;
        public String nextRecordsUrl;
        public List<ToolingRecord> records;
    }

    private class ToolingRecord {
        public Id apexClassOrTriggerId;
        public Id apexTestClassId;
        public NamedRecord apexClassOrTrigger;
        public NamedRecord apexTestClass;
        public Integer numLinesCovered;
        public Integer numLinesUncovered;
        public LineCoverage coverage;
    }

    private class NamedRecord {
        public String name;
    }

    private class LineCoverage {
        public List<Integer> coveredLines;
        public List<Integer> uncoveredLines;
    }

    private class ApexClassHealthException extends Exception {
    }
}
