import XCTest
@testable import OpenOatsKit

final class SpellingGlossaryTests: XCTestCase {

    func testEmptyInputsReturnEmptyList() {
        XCTAssertEqual(SpellingGlossary.terms(global: "", folderGlossary: nil), [])
        XCTAssertEqual(SpellingGlossary.terms(global: "", folderGlossary: ""), [])
        XCTAssertEqual(SpellingGlossary.terms(global: "   \n  \n", folderGlossary: nil), [])
    }

    func testGlobalOnlyParses() {
        let result = SpellingGlossary.terms(global: "EDIR\nGoldfarb\nSmith & Jones LLP", folderGlossary: nil)
        XCTAssertEqual(result, ["EDIR", "Goldfarb", "Smith & Jones LLP"])
    }

    func testFolderOnlyParses() {
        let result = SpellingGlossary.terms(global: "", folderGlossary: "Quirin\nAcme Corp")
        XCTAssertEqual(result, ["Quirin", "Acme Corp"])
    }

    func testTrimsWhitespacePerLine() {
        let result = SpellingGlossary.terms(global: "  EDIR  \n\tGoldfarb\n", folderGlossary: nil)
        XCTAssertEqual(result, ["EDIR", "Goldfarb"])
    }

    func testSkipsEmptyLinesAndComments() {
        let result = SpellingGlossary.terms(global: "EDIR\n\n# notes about names\nGoldfarb\n   #also a comment\n", folderGlossary: nil)
        XCTAssertEqual(result, ["EDIR", "Goldfarb"])
    }

    func testUnionGlobalThenFolderPreservingOrder() {
        let result = SpellingGlossary.terms(global: "EDIR\nGoldfarb", folderGlossary: "Acme Corp\nQuirin")
        XCTAssertEqual(result, ["EDIR", "Goldfarb", "Acme Corp", "Quirin"])
    }

    func testCaseInsensitiveDedup() {
        let result = SpellingGlossary.terms(global: "EDIR\nGoldfarb", folderGlossary: "edir\nGoldfarb\nAcme Corp")
        XCTAssertEqual(result, ["EDIR", "Goldfarb", "Acme Corp"])
    }

    func testPromptBlockEmptyForEmptyTerms() {
        XCTAssertEqual(SpellingGlossary.promptBlock(terms: []), "")
    }

    func testPromptBlockContainsTermsAndInstructions() {
        let block = SpellingGlossary.promptBlock(terms: ["EDIR", "Goldfarb"])
        XCTAssertTrue(block.contains("SPELLING GLOSSARY"))
        XCTAssertTrue(block.contains("- EDIR"))
        XCTAssertTrue(block.contains("- Goldfarb"))
        XCTAssertTrue(block.contains("phonetically"))
        XCTAssertTrue(block.contains("Do NOT"))
    }
}
