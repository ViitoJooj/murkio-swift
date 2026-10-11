import Foundation
import XCTest
@testable import MurkioIdentity

final class ValidateTests: XCTestCase {
    private func fixtures(_ kind: String) -> [URL] {
        let directory = specDirectory.appendingPathComponent("canvas/fixtures/\(kind)")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func document(of file: URL) -> JSONValue? {
        (try? String(contentsOf: file, encoding: .utf8)).flatMap(JSONValue.parse)?["document"]
    }

    // The SDK skips what the server would reject but cannot hurt the app (an
    // unknown field or prop): it never reads them, so the document still draws.
    private let ignoredByTheSDK: Set<String> = ["unknown-field.json", "unknown-prop.json"]

    func testAcceptsTheDefaultCanvasUnchanged() {
        let result = sanitizeDocument(readSpec("canvas/default.json"))
        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(result.document?.signIn.elements.count, 9)
        XCTAssertTrue(result.document.map { canSignIn($0.signIn) } ?? false)
        XCTAssertEqual(result.document, defaultCanvas())
    }

    func testValidFixturesHaveNoStructuralProblem() {
        for kind in ["valid", "unpublishable"] {
            let files = fixtures(kind)
            XCTAssertFalse(files.isEmpty, kind)
            for file in files {
                let result = sanitizeDocument(document(of: file))
                XCTAssertEqual(result.problems, [], "\(kind)/\(file.lastPathComponent)")
                XCTAssertNotNil(result.document, "\(kind)/\(file.lastPathComponent)")
            }
        }
    }

    func testInvalidFixturesAreCaught() {
        let files = fixtures("invalid")
        XCTAssertGreaterThan(files.count, 10)
        for file in files {
            let result = sanitizeDocument(document(of: file))
            if ignoredByTheSDK.contains(file.lastPathComponent) {
                XCTAssertNotNil(result.document, file.lastPathComponent)
                continue
            }
            XCTAssertTrue(result.document == nil || !result.problems.isEmpty, file.lastPathComponent)
        }
    }

    func testLinksOnlyGoToHttpsOrASitePath() {
        XCTAssertTrue(isSafeHref("https://example.com/terms"))
        XCTAssertTrue(isSafeHref("https://example.com:8443/terms?x=1#top"))
        XCTAssertTrue(isSafeHref("/terms"))
        let bad: [JSONValue] = [
            "//evil.example", "/\\evil.example", "javascript:alert(1)", "http://example.com", "https://user:pw@example.com",
            "https://exa mple.com", "myapp://callback", "https://", "https:///path", "https://:443/", 42, .null,
        ]
        for value in bad { XCTAssertFalse(isSafeHref(value), value.write()) }
        XCTAssertFalse(isSafeHref(nil))
    }

    /// The default canvas with one member of one element replaced.
    private func canvas(element index: Int, set member: String, to value: JSONValue) -> JSONValue {
        guard case .object(var root) = readSpec("canvas/default.json"), case .object(var screens)? = root["screens"],
              case .object(var signIn)? = screens["sign_in"], case .array(var elements)? = signIn["elements"],
              case .object(var element) = elements[index]
        else { fatalError("unexpected default canvas") }
        element[member] = value
        elements[index] = .object(element)
        signIn["elements"] = .array(elements)
        screens["sign_in"] = .object(signIn)
        root["screens"] = .object(screens)
        return .object(root)
    }

    func testATextWithBidiOrControlCharactersDropsItsElement() {
        let bidi = String(Unicode.Scalar(0x202E)!)
        let isolate = String(Unicode.Scalar(0x2066)!)
        let bell = String(Unicode.Scalar(7))
        for bad in ["Sign\(bidi)in", "a\(bell)b", "x\(isolate)y", "   "] {
            let result = sanitizeDocument(canvas(element: 0, set: "props", to: ["text": ["default": .string(bad)], "variant": "h1"]))
            XCTAssertEqual(result.document?.signIn.elements.contains { $0.id == "title" }, false)
            XCTAssertFalse(result.problems.isEmpty)
        }
    }

    func testOnlyTheTextElementKeepsLineBreaks() {
        let title = sanitizeDocument(canvas(element: 0, set: "props", to: ["text": ["default": "two\nlines"]]))
        XCTAssertEqual(title.problems, [])
        let button = sanitizeDocument(canvas(element: 6, set: "props", to: ["label": ["default": "two\nlines"]]))
        XCTAssertFalse(button.problems.isEmpty)
    }

    func testAStyleOutOfRangeIsIgnoredAndTheElementStays() {
        let result = sanitizeDocument(canvas(element: 6, set: "style", to: [
            "font_size": 500, "opacity": 3, "color": "url(javascript:1)", "radius": 12, "position": "fixed",
        ]))
        let login = result.document?.signIn.elements.first { $0.id == "login" }
        XCTAssertNotNil(login)
        XCTAssertNil(login?.style.fontSize)
        XCTAssertNil(login?.style.opacity)
        XCTAssertNil(login?.style.color)
        XCTAssertEqual(login?.style.radius, 12)
        XCTAssertEqual(result.problems.count, 4)
    }

    func testNumbersWrittenAs8Point0CountAsIntegers() {
        let login = sanitizeDocument(canvas(element: 6, set: "style", to: ["radius": 8.0, "padding": 8.5]))
            .document?.signIn.elements.first { $0.id == "login" }
        XCTAssertEqual(login?.style.radius, 8)
        XCTAssertNil(login?.style.padding)

        let text = readSpec("canvas/default.json").write().replacingOccurrences(of: "\"radius\":8", with: "\"radius\":8.0")
        XCTAssertEqual(sanitizeDocument(JSONValue.parse(text)).document?.theme.radius, 8)
    }

    func testADocumentThatIsNotASchema1CanvasIsRefused() {
        let bad: [JSONValue?] = [nil, .null, "x", 3, [], [:], ["schema": 2]]
        for value in bad { XCTAssertNil(sanitizeDocument(value).document) }
        XCTAssertNil(sanitizeDocument(JSONValue.parse("{not json")).document)
    }

    func testTheJSONReaderIsStrictAndRoundTrips() {
        let text = #"{"a":[1,2.5,-3e2,true,false,null],"b":{"c":"line\nbreak é \"quoted\" \\ \/ 😀"},"d":""}"#
        let value = JSONValue.parse(text)
        XCTAssertEqual(value?["a"], [1, 2.5, -300, true, false, .null])
        XCTAssertEqual(value?["b"]?["c"]?.string, "line\nbreak \u{e9} \"quoted\" \\ / \u{1F600}")
        XCTAssertEqual(value.flatMap { JSONValue.parse($0.write()) }, value)
        XCTAssertEqual(JSONValue.object(["n": 3, "f": 0.5, "z": .null]).write(), #"{"f":0.5,"n":3,"z":null}"#)
        XCTAssertEqual(JSONValue.parse(#""\ud83d""#)?.string, "\u{FFFD}", "a lone surrogate is replaced")

        for bad in ["", "{", "[1,]", #"{"a":1,}"#, "01", "1.", "nul", "\"unterminated", #"{"a" 1}"#, "[1] x", "'single'", "\"tab\there\""] {
            XCTAssertNil(JSONValue.parse(bad), bad)
        }
        XCTAssertNil(JSONValue.parse(String(repeating: "[", count: 100) + String(repeating: "]", count: 100)))
    }
}
