import UniformTypeIdentifiers
import XCTest

@testable import ZestCore

final class WheelTreeTests: XCTestCase {
  private func tool(
    _ id: String, root: ToolSpec.Root, accepts: Set<UTType>, shape: ToolSpec.Shape = .transform,
    status: ToolSpec.Status = .ready
  ) -> ToolSpec {
    ToolSpec(
      id: id, backendID: "t", root: root, title: id, symbol: "doc", shape: shape,
      accepts: accepts, status: status)
  }

  private func cap(_ input: UTType, _ output: UTType) -> Capability {
    Capability(backendID: "c", input: [input], output: output, quality: 80, isNative: true)
  }

  private func titles(_ node: WheelNode) -> [String] { node.children.map(\.title) }

  func testRootsAreFourAndPrunedToWhatApplies() {
    let router = Router(
      capabilities: [cap(.png, .jpeg)],
      tools: [
        tool("compress", root: .compress, accepts: [.image]),
        tool("strip", root: .files, accepts: [.image]),
        tool("crop", root: .edit, accepts: [.image], status: .needsEditor),
      ])
    let tree = WheelTree.build(router: router, inputs: [.png])
    XCTAssertEqual(titles(tree), ["Convert", "Compress", "Edit", "Files"])
  }

  func testBranchWithNoApplicableLeafIsHidden() {
    let router = Router(
      capabilities: [cap(.pdf, .png)],
      tools: [tool("compress", root: .compress, accepts: [.image])])
    let tree = WheelTree.build(router: router, inputs: [.pdf])
    XCTAssertEqual(titles(tree), ["Convert"])
  }

  func testEditorToolsAreShownDisabledWithAReason() {
    let router = Router(
      capabilities: [],
      tools: [tool("crop", root: .edit, accepts: [.image], status: .needsEditor)])
    let edit = WheelTree.build(router: router, inputs: [.png]).children[0]
    XCTAssertEqual(edit.children[0].title, "crop")
    XCTAssertNotNil(edit.children[0].disabledReason)
    XCTAssertFalse(edit.children[0].isDroppable)
  }

  func testLiveEditorsAreEnabledMarkedAndSingleFileOnly() {
    let crop = ToolSpec(
      id: "crop.image", backendID: "editor", root: .edit, title: "Crop", symbol: "crop",
      accepts: [.image], status: .opensEditor, maxInputs: 1)
    let router = Router(capabilities: [], tools: [crop])

    let single = WheelTree.build(router: router, inputs: [.png]).children[0].children[0]
    XCTAssertTrue(single.isEnabled)
    XCTAssertTrue(single.opensEditor)
    XCTAssertTrue(single.isDroppable)

    XCTAssertEqual(router.visibility(of: crop, inputs: [.png, .png]), .hidden(.needsSingleFile))
    XCTAssertTrue(WheelTree.build(router: router, inputs: [.png, .jpeg]).children.isEmpty)
  }

  func testPerSelectionReasonDimsAnOtherwiseReadyTool() {
    let crop = ToolSpec(
      id: "crop.image", backendID: "editor", root: .edit, title: "Crop", symbol: "crop",
      accepts: [.image], status: .opensEditor, maxInputs: 1)
    let router = Router(capabilities: [], tools: [crop])
    let tree = WheelTree.build(
      router: router, inputs: [.tiff], dimmed: ["crop.image": "Multi-page images can't be edited yet."])
    let leaf = tree.children[0].children[0]
    XCTAssertFalse(leaf.isEnabled)
    XCTAssertFalse(leaf.isDroppable)
    XCTAssertEqual(leaf.disabledReason, "Multi-page images can't be edited yet.")
  }

  func testWrongTypeToolsAreHiddenNotDimmed() {
    let router = Router(
      capabilities: [],
      tools: [
        tool("crop", root: .edit, accepts: [.image], status: .needsEditor),
        tool("bleep", root: .edit, accepts: [.audio], status: .needsEditor),
      ])
    let edit = WheelTree.build(router: router, inputs: [.mp3]).children[0]
    XCTAssertEqual(titles(edit), ["bleep"])
  }

  func testGroupToolsNeedEnoughFiles() {
    let merge = tool("merge", root: .files, accepts: [.pdf], shape: .group(minimum: 2))
    let router = Router(capabilities: [], tools: [merge])
    XCTAssertTrue(WheelTree.build(router: router, inputs: [.pdf]).children.isEmpty)
    XCTAssertEqual(titles(WheelTree.build(router: router, inputs: [.pdf, .pdf])), ["Files"])
    XCTAssertEqual(
      router.visibility(of: merge, inputs: [.pdf]), .hidden(.needsAtLeast(2)))
  }

  func testMixedSelectionShowsOnlyToolsEveryFileSupports() {
    let router = Router(
      capabilities: [],
      tools: [
        tool("images", root: .compress, accepts: [.image]),
        tool("both", root: .compress, accepts: [.image, .movie]),
      ])
    let mixed = WheelTree.build(router: router, inputs: [.png, .heic])
    XCTAssertEqual(titles(mixed.children[0]), ["images", "both"])
    let crossType = WheelTree.build(router: router, inputs: [.png, .mpeg4Movie])
    XCTAssertEqual(titles(crossType.children[0]), ["both"])
  }

  func testMissingEngineDimsTheToolWithItsReason() {
    let strip = tool("strip", root: .files, accepts: [.movie])
    let router = Router(
      capabilities: [], tools: [strip],
      unavailableTools: [UnavailableTool(tool: strip, reason: "FFmpeg was not found")])
    XCTAssertEqual(
      router.visibility(of: strip, inputs: [.mpeg4Movie]),
      .disabled(.backendUnavailable(backend: "t", reason: "FFmpeg was not found")))
  }

  func testOverflowBecomesAMoreBranchHoldingTheRest() {
    let outputs: [UTType] = [.jpeg, .png, .heic, .tiff, .gif, .bmp, .webP, .pdf, .svg, .ico]
    let caps = outputs.map { cap(.rawImage, $0) }
    let tree = WheelTree.build(router: Router(capabilities: caps), inputs: [.rawImage])
    let convert = tree.children[0]
    XCTAssertEqual(convert.children.count, WheelGeometry.maxWedges)
    let more = try! XCTUnwrap(convert.children.last)
    XCTAssertTrue(more.isBranch)
    XCTAssertEqual(more.title, "More")
    XCTAssertEqual(convert.children.count - 1 + more.children.count, outputs.count)
  }

  func testEveryRingFitsTheWheel() {
    func check(_ node: WheelNode) {
      XCTAssertLessThanOrEqual(node.children.count, WheelGeometry.maxWedges, node.id)
      node.children.forEach(check)
    }
    let outputs = (0..<30).map { UTType(filenameExtension: "x\($0)") ?? .data }
    let router = Router(capabilities: Set(outputs).map { cap(.png, $0) })
    check(WheelTree.build(router: router, inputs: [.png]))
  }
}

final class WheelNavigatorTests: XCTestCase {
  private func leaf(_ id: String) -> WheelNode {
    WheelNode(id: id, title: id, symbol: "doc", action: .tool(id))
  }

  private func branch(_ id: String, _ children: [WheelNode]) -> WheelNode {
    WheelNode(id: id, title: id, symbol: "folder", action: .branch, children: children)
  }

  /// root → [A (leaves a1 a2), B (branch → [b1 branch → [deep]])]
  private func makeNavigator() -> WheelNavigator {
    let deep = branch("deep", [leaf("d1")])
    let root = branch(
      "root", [
        branch("A", [leaf("a1"), leaf("a2")]),
        branch("B", [branch("b1", [deep]), leaf("b2")]),
      ])
    return WheelNavigator(root: root, dwell: 0.5)
  }

  private func over(_ nav: inout WheelNavigator, _ index: Int, at now: Double, dx: Double = 0, dy: Double = 90) {
    nav.pointerMoved(hit: .wedge(index), dx: dx, dy: dy, now: now)
  }

  func testHoldingOverABranchDescendsAfterTheDwell() {
    var nav = makeNavigator()
    over(&nav, 0, at: 0)
    XCTAssertNil(nav.tick(now: 0.49))
    XCTAssertEqual(nav.tick(now: 0.5), .descended)
    XCTAssertEqual(nav.current.id, "A")
    XCTAssertEqual(nav.breadcrumb, ["A"])
  }

  func testMovingAwayCancelsTheHold() {
    var nav = makeNavigator()
    over(&nav, 0, at: 0)
    over(&nav, 1, at: 0.3)
    XCTAssertNil(nav.tick(now: 0.5), "the hold restarted on the new target")
    XCTAssertEqual(nav.tick(now: 0.8), .descended)
    XCTAssertEqual(nav.current.id, "B")
  }

  func testLeavingTheRingCancelsTheHold() {
    var nav = makeNavigator()
    over(&nav, 0, at: 0)
    nav.pointerLeft()
    XCTAssertNil(nav.tick(now: 1))
  }

  func testLeavesNeverDwell() {
    var nav = makeNavigator()
    over(&nav, 0, at: 0)
    nav.tick(now: 0.5)
    over(&nav, 0, at: 1, dx: 40, dy: 40)  // leaf a1, after moving off the anchor
    XCTAssertNil(nav.dwellTarget)
    XCTAssertNil(nav.tick(now: 5))
    XCTAssertEqual(nav.current.id, "A")
  }

  func testDisabledBranchesDoNotDescend() {
    let off = WheelNode(
      id: "off", title: "off", symbol: "x", action: .branch, children: [leaf("x")],
      disabledReason: "nope")
    var nav = WheelNavigator(root: branch("root", [off]), dwell: 0.5)
    over(&nav, 0, at: 0)
    XCTAssertNil(nav.tick(now: 2))
  }

  func testHoldingTheCentreGoesBackUp() {
    var nav = makeNavigator()
    over(&nav, 0, at: 0)
    nav.tick(now: 0.5)
    nav.pointerMoved(hit: .deadZone, dx: 0, dy: 0, now: 1)
    XCTAssertEqual(nav.dwellTarget, .centre)
    XCTAssertEqual(nav.tick(now: 1.5), .ascended)
    XCTAssertEqual(nav.current.id, "root")
    XCTAssertFalse(nav.canGoBack)
  }

  func testRootCentreIsNotABackTarget() {
    var nav = makeNavigator()
    nav.pointerMoved(hit: .deadZone, dx: 0, dy: 0, now: 0)
    XCTAssertNil(nav.dwellTarget)
    XCTAssertNil(nav.tick(now: 5))
  }

  // The cascade trap: after a descent the pointer sits over whatever child now occupies
  // that spot. If that child is a branch it must not start dwelling until the pointer moves.
  func testNoCascadeThroughNestedBranchesUnderAStillPointer() {
    var nav = makeNavigator()
    over(&nav, 1, at: 0)  // B
    XCTAssertEqual(nav.tick(now: 0.5), .descended)
    // B's first child b1 is a branch right under the pointer.
    over(&nav, 0, at: 0.6)
    XCTAssertNil(nav.dwellTarget, "dwell must not start under a still pointer")
    XCTAssertNil(nav.tick(now: 5))
    XCTAssertEqual(nav.current.id, "B")
  }

  func testDwellStartsOnceThePointerHasMovedPastTheSettleDistance() {
    var nav = makeNavigator()
    over(&nav, 1, at: 0)
    nav.tick(now: 0.5)
    over(&nav, 0, at: 0.6)  // settles the anchor
    over(&nav, 0, at: 0.7, dx: 0, dy: 90 + WheelNavigator.settleDistance + 1)
    XCTAssertEqual(nav.dwellTarget, .child(0))
    XCTAssertEqual(nav.tick(now: 1.2), .descended)
    XCTAssertEqual(nav.current.id, "b1")
  }

  func testDwellStartsWhenThePointerReachesADifferentTarget() {
    var nav = makeNavigator()
    over(&nav, 1, at: 0)
    nav.tick(now: 0.5)
    over(&nav, 1, at: 0.6)  // b2, a leaf under the pointer: settles
    over(&nav, 0, at: 0.7)  // b1, a branch: different target, dwell may start
    XCTAssertEqual(nav.dwellTarget, .child(0))
  }

  func testDropIsRejectedUntilThePointerSettlesAfterADescent() {
    var nav = makeNavigator()
    over(&nav, 0, at: 0)
    nav.tick(now: 0.5)  // into A: leaves a1, a2
    XCTAssertNil(
      nav.droppableNode(hit: .wedge(0), dx: 0, dy: 90), "a stray release right after the descent")
    over(&nav, 0, at: 0.6)
    XCTAssertNil(nav.droppableNode(hit: .wedge(0), dx: 0, dy: 90))
    XCTAssertEqual(nav.droppableNode(hit: .wedge(0), dx: 0, dy: 110)?.id, "a1")
    XCTAssertEqual(nav.droppableNode(hit: .wedge(1), dx: 0, dy: 90)?.id, "a2")
  }

  func testBranchesAndDisabledLeavesRejectDrops() {
    let dim = WheelNode(
      id: "dim", title: "dim", symbol: "x", action: .tool("dim"), disabledReason: "editor")
    let nav = WheelNavigator(
      root: branch("root", [branch("A", [leaf("a1")]), dim]), dwell: 0.5)
    XCTAssertNil(nav.droppableNode(hit: .wedge(0), dx: 0, dy: 90))
    XCTAssertNil(nav.droppableNode(hit: .wedge(1), dx: 0, dy: 90))
    XCTAssertNil(nav.droppableNode(hit: .gap, dx: 0, dy: 90))
    XCTAssertNil(nav.droppableNode(hit: .outside, dx: 0, dy: 200))
  }

  func testProgressRunsFromZeroToOne() {
    var nav = makeNavigator()
    XCTAssertEqual(nav.dwellProgress(now: 0), 0)
    over(&nav, 0, at: 10)
    XCTAssertEqual(nav.dwellProgress(now: 10.25), 0.5, accuracy: 0.001)
    XCTAssertEqual(nav.dwellProgress(now: 99), 1)
  }

  func testResetReturnsToTheRoot() {
    var nav = makeNavigator()
    over(&nav, 0, at: 0)
    nav.tick(now: 0.5)
    nav.reset()
    XCTAssertEqual(nav.current.id, "root")
    XCTAssertNil(nav.dwellTarget)
  }

  func testOutOfRangeWedgeIsIgnored() {
    var nav = makeNavigator()
    nav.pointerMoved(hit: .wedge(7), dx: 0, dy: 90, now: 0)
    XCTAssertNil(nav.hovered)
  }
}

final class PlannedToolsTests: XCTestCase {
  func testImageEditorsOfferOnlyStillFormats() {
    let router = Router(capabilities: [], tools: PlannedTools.all)
    for id in ["crop.image", "annotate.image", "redact.image", "background.image"] {
      let tool = router.tools.first { $0.id == id }!
      XCTAssertEqual(router.visibility(of: tool, inputs: [.png]), .enabled, id)
      XCTAssertEqual(router.visibility(of: tool, inputs: [.jpeg]), .enabled, id)
      XCTAssertEqual(router.visibility(of: tool, inputs: [.gif]), .hidden(.wrongType(.gif)), id)
      XCTAssertEqual(router.visibility(of: tool, inputs: [.webP]), .hidden(.wrongType(.webP)), id)
    }
  }
}
