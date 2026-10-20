import UniformTypeIdentifiers
import XCTest

@testable import ZestBackends

final class TextDocumentTests: XCTestCase {
  private func text(_ inlines: [Inline]) -> String { inlines.map(\.text).joined() }

  private func tempFile(_ name: String, _ content: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  // MARK: Blocks

  func testHeadings() {
    let blocks = MarkdownParser.parse("# One\n\n## Two ##\n\nThree\n=====\n\nFour\n----\n")
    XCTAssertEqual(blocks.count, 4)
    XCTAssertEqual(blocks[0], .heading(1, [Inline("One")]))
    XCTAssertEqual(blocks[1], .heading(2, [Inline("Two")]))
    XCTAssertEqual(blocks[2], .heading(1, [Inline("Three")]))
    XCTAssertEqual(blocks[3], .heading(2, [Inline("Four")]))
  }

  func testFencedCodeAndRule() {
    let blocks = MarkdownParser.parse("```swift\nlet a = 1\n# not a heading\n```\n\n~~~\nraw\n~~~\n\n---\n")
    XCTAssertEqual(
      blocks,
      [
        .code(language: "swift", text: "let a = 1\n# not a heading"),
        .code(language: nil, text: "raw"),
        .rule,
      ])
  }

  func testUnterminatedFenceRunsToEnd() {
    XCTAssertEqual(MarkdownParser.parse("```\na\nb"), [.code(language: nil, text: "a\nb")])
  }

  func testQuoteAndParagraphSoftBreaks() {
    let blocks = MarkdownParser.parse("> quoted\n> more\n\nline one\nline two\nhard  \nbreak\n")
    XCTAssertEqual(blocks[0], .quote([Inline("quoted more")]))
    XCTAssertEqual(blocks[1], .paragraph([Inline("line one line two hard\nbreak")]))
  }

  func testListsWithDepth() {
    let two = MarkdownParser.parse("- a\n  - b\n    - c\n- d\n")
    XCTAssertEqual(
      two,
      [
        .listItem(ordered: false, depth: 0, [Inline("a")]),
        .listItem(ordered: false, depth: 1, [Inline("b")]),
        .listItem(ordered: false, depth: 2, [Inline("c")]),
        .listItem(ordered: false, depth: 0, [Inline("d")]),
      ])
    let four = MarkdownParser.parse("1. one\n    1. nested\n2. two\n")
    XCTAssertEqual(
      four,
      [
        .listItem(ordered: true, depth: 0, [Inline("one")]),
        .listItem(ordered: true, depth: 1, [Inline("nested")]),
        .listItem(ordered: true, depth: 0, [Inline("two")]),
      ])
  }

  func testTable() {
    let blocks = MarkdownParser.parse("| A | B |\n| --- | :-: |\n| 1 | **2** |\n| x \\| y | z |\n")
    guard case .table(let header, let rows) = blocks.first else { return XCTFail("no table") }
    XCTAssertEqual(header.map(text), ["A", "B"])
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[0][1], [Inline("2", bold: true)])
    XCTAssertEqual(text(rows[1][0]), "x | y")
  }

  func testImageAloneBecomesBlock() {
    XCTAssertEqual(
      MarkdownParser.parse("![a cat](cat.png)"), [.image(alt: "a cat", src: "cat.png", dataURI: nil)])
    let mixed = MarkdownParser.parse("see ![a cat](cat.png) here")
    guard case .paragraph = mixed.first else { return XCTFail("expected paragraph") }
  }

  // MARK: Inlines

  func testInlineStyles() {
    let blocks = MarkdownParser.parse("a **b** _c_ ~~d~~ `e` [f](https://x.y) <https://auto.link> \\*g\\*")
    guard case .paragraph(let inlines) = blocks.first else { return XCTFail("no paragraph") }
    XCTAssertTrue(inlines.contains(Inline("b", bold: true)))
    XCTAssertTrue(inlines.contains(Inline("c", italic: true)))
    XCTAssertTrue(inlines.contains(Inline("d", strike: true)))
    XCTAssertTrue(inlines.contains(Inline("e", code: true)))
    XCTAssertTrue(inlines.contains(Inline("f", link: "https://x.y")))
    XCTAssertTrue(inlines.contains(Inline("https://auto.link", link: "https://auto.link")))
    XCTAssertEqual(text(inlines).suffix(3), "*g*")
  }

  func testNestedEmphasis() {
    let blocks = MarkdownParser.parse("**bold *and italic* text** and ***both***")
    guard case .paragraph(let inlines) = blocks.first else { return XCTFail("no paragraph") }
    XCTAssertTrue(inlines.contains(Inline("and italic", bold: true, italic: true)))
    XCTAssertTrue(inlines.contains(Inline("both", bold: true, italic: true)))
  }

  func testUnterminatedMarkersStayLiteral() {
    let samples = ["**not closed", "a * b * c", "snake_case_name", "`open code", "[no link](", "~~half", "<notatag"]
    for sample in samples {
      guard case .paragraph(let inlines) = MarkdownParser.parse(sample).first else {
        return XCTFail("no paragraph for \(sample)")
      }
      XCTAssertEqual(text(inlines), sample)
      XCTAssertTrue(inlines.allSatisfy { !$0.bold && !$0.italic && !$0.strike && !$0.code && $0.link == nil })
    }
  }

  // MARK: Round trips and escaping

  func testRoundTripThroughMarkdownWriter() {
    let source = """
      # Title

      Some **bold** and *italic* with `code` and a [link](https://example.com).

      - one
        - nested
      - two

      1. first
      2. second

      > quote

      ```swift
      let x = 1
      ```

      | A | B |
      | --- | --- |
      | 1 | 2 |

      ---
      """
    let first = MarkdownParser.parse(source)
    let rendered = MarkdownWriter.render(Document(title: "t", blocks: first))
    XCTAssertEqual(MarkdownParser.parse(rendered), first)
  }

  func testWriterEscapesSurviveRoundTrip() {
    let blocks: [Block] = [
      .paragraph([Inline("# not a heading")]), .paragraph([Inline("1. not a list *star*")]),
    ]
    let rendered = MarkdownWriter.render(Document(title: "t", blocks: blocks))
    XCTAssertEqual(MarkdownParser.parse(rendered), blocks)
  }

  func testHTMLIsEscapedAndUnsafeLinksNeutralised() {
    let blocks = MarkdownParser.parse("<script>alert(1)</script> [click](javascript:alert(1)) [ok](https://ok.dev)")
    let html = HTMLWriter.render(Document(title: "t", blocks: blocks))
    XCTAssertFalse(html.contains("<script>"))
    XCTAssertTrue(html.contains("&lt;script&gt;"))
    XCTAssertFalse(html.lowercased().contains("javascript:"))
    XCTAssertTrue(html.contains("<a href=\"https://ok.dev\">ok</a>"))
  }

  // MARK: TextReader

  func testMarkdownFileTitleFromFirstHeading() throws {
    let url = try tempFile("notes.md", "intro\n\n## Real Title\n\nbody")
    let doc = try TextReader.read(url: url, type: UTType("net.daringfireball.markdown") ?? .plainText)
    XCTAssertEqual(doc.title, "Real Title")
    let bare = try tempFile("plain-name.md", "just text")
    XCTAssertEqual(try TextReader.read(url: bare, type: .plainText).title, "plain-name")
  }

  func testPlainTextHardBreaks() throws {
    let url = try tempFile("a.txt", "line1\nline2\n\n\npara two\n")
    let doc = try TextReader.read(url: url, type: .plainText)
    XCTAssertEqual(doc.title, "a")
    XCTAssertEqual(doc.blocks, [.paragraph([Inline("line1\nline2")]), .paragraph([Inline("para two")])])
  }

  func testCSVQuoting() throws {
    let csv = "name,note\r\n\"Smith, J\",\"said \"\"hi\"\"\"\r\n\"multi\nline\",plain\r\n"
    let url = try tempFile("data.csv", csv)
    let doc = try TextReader.read(url: url, type: .commaSeparatedText)
    guard case .table(let header, let rows) = doc.blocks.first else { return XCTFail("no table") }
    XCTAssertEqual(header.map(text), ["name", "note"])
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(text(rows[0][0]), "Smith, J")
    XCTAssertEqual(text(rows[0][1]), "said \"hi\"")
    XCTAssertEqual(text(rows[1][0]), "multi\nline")
  }

  func testTSV() throws {
    let url = try tempFile("d.tsv", "a\tb\n1\t2\n")
    let doc = try TextReader.read(url: url, type: .tabSeparatedText)
    guard case .table(let header, let rows) = doc.blocks.first else { return XCTFail("no table") }
    XCTAssertEqual(header.map(text), ["a", "b"])
    XCTAssertEqual(rows.map { $0.map(text) }, [["1", "2"]])
  }

  func testSourceFilesBecomeCodeBlock() throws {
    let url = try tempFile("config.json", "{\"a\": 1}\n")
    let doc = try TextReader.read(url: url, type: .json)
    XCTAssertEqual(doc.blocks, [.code(language: "json", text: "{\"a\": 1}")])
    let yml = try tempFile("ci.yml", "a: b\n")
    XCTAssertEqual(try TextReader.read(url: yml, type: .yaml).blocks, [.code(language: "yaml", text: "a: b")])
  }

  func testLatin1FallbackAndUnreadable() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("l.txt")
    try Data([0x63, 0x61, 0x66, 0xE9]).write(to: url)  // "caf\u{E9}" in Latin-1
    let doc = try TextReader.read(url: url, type: .plainText)
    XCTAssertEqual(doc.blocks, [.paragraph([Inline("café")])])
    XCTAssertThrowsError(try TextReader.read(url: dir.appendingPathComponent("missing.txt"), type: .plainText))
  }
}
