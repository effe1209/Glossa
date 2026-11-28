import XCTest
@testable import LegacyMigration

// GLOSSA_* is canonical, PAGEFLOW_* a temporary alias. Every test injects the variables: none reads
// the real process environment.
final class AppEnvironmentTests: XCTestCase {
    private func env(_ pairs: [String: String]) -> AppEnvironment { AppEnvironment(pairs) }

    func testOnlyTheCanonicalVariableIsUsed() {
        XCTAssertEqual(env(["GLOSSA_QA_RUN_ID": "new"]).value("QA_RUN_ID"), "new")
    }

    func testOnlyTheLegacyVariableStillWorks() {
        XCTAssertEqual(env(["PAGEFLOW_QA_RUN_ID": "old"]).value("QA_RUN_ID"), "old")
    }

    func testTheCanonicalVariableWinsWhenBothAreSet() {
        let both = env(["GLOSSA_QA_OUTPUT_DIR": "/new", "PAGEFLOW_QA_OUTPUT_DIR": "/old"])
        XCTAssertEqual(both.value("QA_OUTPUT_DIR"), "/new")
    }

    func testAnEmptyCanonicalVariableStillWinsAndNeverFallsBackToTheLegacyOne() {
        let e = env(["GLOSSA_QA_PDF_MODE": "", "PAGEFLOW_QA_PDF_MODE": "cold"])
        XCTAssertEqual(e.value("QA_PDF_MODE"), "")
        XCTAssertTrue(e.isSet("QA_PDF_MODE"))
    }

    func testNoVariableMeansNoValue() {
        let e = env(["HOME": "/x", "UNRELATED": "1"])
        XCTAssertNil(e.value("QA_RUN_ID"))
        XCTAssertFalse(e.isSet("QA_RUN_ID"))
        XCTAssertFalse(e.hasQAVariable)
    }

    func testAPresenceFlagIsSetByEitherNamespace() {
        XCTAssertTrue(env(["GLOSSA_PERF_TRACE": ""]).isSet("PERF_TRACE"))
        XCTAssertTrue(env(["PAGEFLOW_PERF_TRACE": ""]).isSet("PERF_TRACE"))
    }

    func testQADetectionSeesBothNamespacesAndOnlyQANames() {
        XCTAssertTrue(env(["GLOSSA_QA_SCENARIO": "x"]).hasQAVariable)
        XCTAssertTrue(env(["PAGEFLOW_QA_SCENARIO": "x"]).hasQAVariable)
        XCTAssertFalse(env(["GLOSSA_PERF_TRACE": "1", "PAGEFLOW_SCROLL_TRACE": "1"]).hasQAVariable)
        XCTAssertFalse(env(["OTHER_QA_THING": "1"]).hasQAVariable)
    }

    func testTheCanonicalBackgroundSettingPrevailsInBothDirections() {
        XCTAssertEqual(env(["GLOSSA_QA_BACKGROUND": "0", "PAGEFLOW_QA_BACKGROUND": "1"]).value("QA_BACKGROUND"), "0")
        XCTAssertEqual(env(["GLOSSA_QA_BACKGROUND": "1", "PAGEFLOW_QA_BACKGROUND": "0"]).value("QA_BACKGROUND"), "1")
    }

    func testNamesAreCaseSensitive() {
        XCTAssertNil(env(["glossa_qa_run_id": "x"]).value("QA_RUN_ID"))
    }
}
