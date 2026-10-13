@IsTest
private class ApexClassHealthControllerTest {
    private static final String CONTROLLER_CLASS = 'ApexClassHealthController';
    private static final String TEST_CLASS = 'ApexClassHealthControllerTest';

    private class ToolingApiMock implements HttpCalloutMock {
        private final Integer statusCode;
        private final List<Object> aggregateRecords = new List<Object>();
        private final List<Object> coverageRecords = new List<Object>();
        public Integer requestCount = 0;

        public ToolingApiMock(Integer statusCode) {
            this.statusCode = statusCode;
        }

        public ToolingApiMock withAggregate(Id classId, Integer linesCovered, Integer linesUncovered) {
            aggregateRecords.add(
                new Map<String, Object>{
                    'ApexClassOrTriggerId' => classId,
                    'NumLinesCovered' => linesCovered,
                    'NumLinesUncovered' => linesUncovered
                }
            );
            return this;
        }

        public ToolingApiMock withCoverage(
            Id testClassId,
            Id classId,
            List<Integer> coveredLines,
            List<Integer> uncoveredLines
        ) {
            coverageRecords.add(
                new Map<String, Object>{
                    'ApexTestClassId' => testClassId,
                    'ApexTestClass' => new Map<String, Object>{ 'Name' => TEST_CLASS },
                    'ApexClassOrTriggerId' => classId,
                    'ApexClassOrTrigger' => new Map<String, Object>{ 'Name' => CONTROLLER_CLASS },
                    'Coverage' => new Map<String, Object>{
                        'coveredLines' => coveredLines,
                        'uncoveredLines' => uncoveredLines
                    }
                }
            );
            return this;
        }

        public HttpResponse respond(HttpRequest request) {
            requestCount++;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(statusCode);
            if (statusCode != 200) {
                response.setStatus('Unauthorized');
                return response;
            }

            // Each query's first page links to an empty second page to exercise Tooling API pagination.
            String endpoint = EncodingUtil.urlDecode(request.getEndpoint(), 'UTF-8');
            Boolean isFirstPage = !endpoint.endsWith('-2000');
            List<Object> records = new List<Object>();
            if (isFirstPage) {
                records = endpoint.contains('FROM ApexCodeCoverageAggregate') ? aggregateRecords : coverageRecords;
            }
            response.setBody(
                JSON.serialize(
                    new Map<String, Object>{
                        'done' => !isFirstPage,
                        'nextRecordsUrl' => isFirstPage ? '/services/data/v66.0/tooling/query/01gTEST-2000' : null,
                        'records' => records
                    }
                )
            );
            return response;
        }
    }

    @IsTest
    static void returnsClassesWithCoverageAndGrades() {
        Id controllerId = getClassId(CONTROLLER_CLASS);
        ToolingApiMock mock = new ToolingApiMock(200).withAggregate(controllerId, 9, 1);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        ApexClassHealthController.HealthReport report = ApexClassHealthController.getApexClassHealth();
        Test.stopTest();

        Assert.isTrue(report.coverageAvailable, 'Coverage should be available when the Tooling API responds');
        Assert.isNull(report.coverageMessage, 'No coverage notice is expected');
        Assert.areEqual(2, mock.requestCount, 'Every Tooling API result page should be requested');
        Assert.isTrue(report.triggerCharacters >= 0, 'Trigger characters should be totalled for the Apex usage tile');

        ApexClassHealthController.ClassHealth controller = findClass(report, CONTROLLER_CLASS);
        Assert.areEqual(90.00, controller.coverage, 'Coverage should be covered lines over executable lines');
        Assert.areEqual(9, controller.linesCovered, 'Covered lines should come from the Tooling API');
        Assert.areEqual('A', controller.grade, 'A well covered, current and compact class should be graded A');
        Assert.isFalse(controller.isTest, 'The controller is not a test class');
        Assert.isTrue(controller.linesOfCode > 0, 'Lines of code should be counted from the class body');

        ApexClassHealthController.ClassHealth testClass = findClass(report, TEST_CLASS);
        Assert.isTrue(testClass.isTest, 'Classes annotated with @IsTest should be flagged as tests');
        Assert.isNull(testClass.coverage, 'Test classes have no coverage of their own');
    }

    @IsTest
    static void reportsMissingCoverageData() {
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200));

        Test.startTest();
        ApexClassHealthController.HealthReport report = ApexClassHealthController.getApexClassHealth();
        Test.stopTest();

        Assert.isFalse(report.coverageAvailable, 'Coverage is unavailable when no aggregate records exist');
        Assert.isTrue(
            report.coverageMessage.startsWith('No code coverage data'),
            'Users should be told to run their tests'
        );
    }

    @IsTest
    static void returnsClassesWhenToolingApiFails() {
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(401));

        Test.startTest();
        ApexClassHealthController.HealthReport report = ApexClassHealthController.getApexClassHealth();
        Test.stopTest();

        Assert.isFalse(report.coverageAvailable, 'Coverage should be unavailable after a failed callout');
        Assert.isTrue(report.coverageMessage.contains('401'), 'The notice should include the HTTP status');

        ApexClassHealthController.ClassHealth controller = findClass(report, CONTROLLER_CLASS);
        Assert.isNull(controller.coverage, 'No coverage is reported without Tooling API data');
        Assert.areEqual('A', controller.grade, 'Grades fall back to API version and size');
    }

    @IsTest
    static void plansTestRunFromTestsCoveringSelectedClasses() {
        Id controllerId = getClassId(CONTROLLER_CLASS);
        Id testClassId = getClassId(TEST_CLASS);
        Test.setMock(
            HttpCalloutMock.class,
            new ToolingApiMock(200).withCoverage(testClassId, controllerId, new List<Integer>{ 1 }, new List<Integer>{ 2 })
        );

        Test.startTest();
        ApexClassHealthController.TestRun run = ApexClassHealthController.planTestRun(new List<Id>{ controllerId });
        Test.stopTest();

        Assert.areEqual(new List<Id>{ testClassId }, run.testClassIds, 'Tests covering the selected class should run');
        Assert.isTrue(run.classesWithoutTests.isEmpty(), 'Every selected class has a covering test');
    }

    @IsTest
    static void plansTestRunForSelectedTestClassesWithoutCallouts() {
        Id testClassId = getClassId(TEST_CLASS);
        ToolingApiMock mock = new ToolingApiMock(200);
        Test.setMock(HttpCalloutMock.class, mock);

        ApexClassHealthController.TestRun run = ApexClassHealthController.planTestRun(new List<Id>{ testClassId });

        Assert.areEqual(new List<Id>{ testClassId }, run.testClassIds, 'Selected test classes should run as they are');
        Assert.areEqual(0, mock.requestCount, 'Test classes need no Tooling API lookup');
    }

    @IsTest
    static void runTestsFailsWhenNoTestsCoverTheSelection() {
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200));

        try {
            ApexClassHealthController.runTests(new List<Id>{ getClassId(CONTROLLER_CLASS) });
            Assert.fail('Expected an error when no tests cover the selection');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().startsWith('No tests found'), 'The error should explain why nothing ran');
        }
    }

    @IsTest
    static void reportsStatusOfAFinishedRun() {
        Id jobWithoutQueuedClasses = '707000000000000AAA';

        ApexClassHealthController.TestRunStatus status = ApexClassHealthController.getTestRunStatus(
            jobWithoutQueuedClasses
        );

        Assert.isTrue(status.isComplete, 'A job with no queued classes has nothing left to wait for');
        Assert.areEqual(0, status.methodsPassed, 'No test methods ran');
        Assert.isTrue(status.failures.isEmpty(), 'No test methods failed');
    }

    @IsTest
    static void listsClassesCoveredByTests() {
        Id controllerId = getClassId(CONTROLLER_CLASS);
        Id testClassId = getClassId(TEST_CLASS);
        Test.setMock(
            HttpCalloutMock.class,
            new ToolingApiMock(200)
                .withCoverage(testClassId, controllerId, new List<Integer>{ 1 }, new List<Integer>{ 2 })
                .withAggregate(controllerId, 9, 1)
        );

        Test.startTest();
        List<ApexClassHealthController.CoverageItem> items = ApexClassHealthController.getClassesCoveredByTests(
            new List<Id>{ testClassId }
        );
        Test.stopTest();

        Assert.areEqual(1, items.size(), 'Only the covered class should be listed');
        Assert.areEqual(CONTROLLER_CLASS, items[0].name, 'The covered class should be named');
        Assert.areEqual(90.00, items[0].coverage, 'The overall coverage of the class should be shown');
        Assert.areEqual(10, items[0].linesTotal, 'Total executable lines should come from the aggregate');
    }

    @IsTest
    static void mergesTestMethodsWhenListingTestsCoveringAClass() {
        Id controllerId = getClassId(CONTROLLER_CLASS);
        Id testClassId = getClassId(TEST_CLASS);
        Test.setMock(
            HttpCalloutMock.class,
            new ToolingApiMock(200)
                .withCoverage(testClassId, controllerId, new List<Integer>{ 1, 2 }, new List<Integer>{ 3, 4 })
                .withCoverage(testClassId, controllerId, new List<Integer>{ 2, 3 }, new List<Integer>{ 1, 4 })
        );

        Test.startTest();
        List<ApexClassHealthController.CoverageItem> items = ApexClassHealthController.getTestsCoveringClass(
            controllerId
        );
        Test.stopTest();

        Assert.areEqual(1, items.size(), 'Rows from one test class should be merged');
        Assert.areEqual(TEST_CLASS, items[0].name, 'The covering test class should be named');
        Assert.areEqual(75.00, items[0].coverage, 'Lines covered by several test methods should count once');
    }

    @IsTest
    static void appliesGradeRubric() {
        Assert.areEqual('A', buildGradedClass(95, false, 66, 100, true).grade, 'Coverage of 90% or more');
        Assert.areEqual('B', buildGradedClass(80, false, 66, 100, true).grade, 'Coverage between 75% and 90%');
        Assert.areEqual('C', buildGradedClass(60, false, 66, 100, true).grade, 'Coverage between 50% and 75%');
        Assert.areEqual('D', buildGradedClass(40, false, 66, 100, true).grade, 'Coverage below 50%');
        Assert.areEqual('D', buildGradedClass(null, false, 66, 100, true).grade, 'Classes without coverage data');
        Assert.areEqual('B', buildGradedClass(95, false, 50, 100, true).grade, 'Outdated API drops one grade');
        Assert.areEqual('D', buildGradedClass(60, false, 50, 1500, true).grade, 'Grades never drop below D');
        Assert.areEqual('A', buildGradedClass(null, true, 66, 100, true).grade, 'Test classes skip coverage');
        Assert.areEqual('A', buildGradedClass(null, false, 66, 100, false).grade, 'Coverage ignored if unavailable');

        ApexClassHealthController.ClassHealth largeOutdatedClass = buildGradedClass(95, false, 50, 1500, true);
        Assert.areEqual('C', largeOutdatedClass.grade, 'Outdated API version and size each drop one grade');
        Assert.areEqual(
            'API version more than 3 years old; More than 1000 lines',
            largeOutdatedClass.findings,
            'Findings should explain the grade'
        );
    }

    private static ApexClassHealthController.ClassHealth buildGradedClass(
        Decimal coverage,
        Boolean isTest,
        Decimal apiVersion,
        Integer linesOfCode,
        Boolean coverageAvailable
    ) {
        ApexClassHealthController.ClassHealth item = new ApexClassHealthController.ClassHealth();
        item.coverage = coverage;
        item.isTest = isTest;
        item.apiVersion = apiVersion;
        item.linesOfCode = linesOfCode;
        ApexClassHealthController.applyGrade(item, coverageAvailable, 66);
        return item;
    }

    private static ApexClassHealthController.ClassHealth findClass(
        ApexClassHealthController.HealthReport report,
        String name
    ) {
        for (ApexClassHealthController.ClassHealth item : report.classes) {
            if (item.name == name) {
                return item;
            }
        }
        Assert.fail('Expected ' + name + ' in the report');
        return null;
    }

    private static Id getClassId(String name) {
        return [SELECT Id FROM ApexClass WHERE Name = :name LIMIT 1].Id;
    }
}
