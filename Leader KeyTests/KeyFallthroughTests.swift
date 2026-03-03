import Combine
import Defaults
import XCTest

@testable import Leader_Key

class KeyFallthroughTests: XCTestCase {
  var controller: Controller!
  var cancellables: Set<AnyCancellable>!
  var userState: UserState!
  var userConfig: UserConfig!
  var tempDir: String!

  // Reusable test config:
  // root: [t=action, a=group([x=action, b=group([y=action])])]
  private func makeConfig() -> Group {
    let innerAction = Action(key: "y", type: .application, value: "/Apps/Y.app")
    let innerGroup = Group(
      key: "b", label: "Inner",
      actions: [.action(innerAction)])

    let midAction = Action(key: "x", type: .application, value: "/Apps/X.app")
    let midGroup = Group(
      key: "a", label: "Mid",
      actions: [.action(midAction), .group(innerGroup)])

    let rootAction = Action(key: "t", type: .application, value: "/Apps/T.app")
    let rootGroup2 = Group(
      key: "r", label: "Root Group",
      actions: [.action(Action(key: "z", type: .application, value: "/Apps/Z.app"))])

    return Group(
      key: nil,
      actions: [.action(rootAction), .group(midGroup), .group(rootGroup2)])
  }

  override func setUp() {
    super.setUp()
    cancellables = Set<AnyCancellable>()

    // Use a temp directory so saves don't corrupt the real config
    tempDir = NSTemporaryDirectory().appending("/LeaderKeyFallthroughTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    Defaults[.configDir] = tempDir

    // Write config as a JSON file and load it (avoids triggering saveConfigAsync,
    // since ensureAndLoad sets isLoading=true before assigning root)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    let data = try! encoder.encode(makeConfig())
    let configPath = (tempDir as NSString).appendingPathComponent("config.json")
    try! data.write(to: URL(fileURLWithPath: configPath))

    userConfig = UserConfig()
    userConfig.ensureAndLoad()
    waitForConfigLoad()

    userState = UserState(userConfig: userConfig)
    controller = Controller(userState: userState, userConfig: userConfig)

    Defaults[.keyFallthroughEnabled] = false
  }

  override func tearDown() {
    cancellables = nil
    controller = nil
    userState = nil
    userConfig = nil
    try? FileManager.default.removeItem(atPath: tempDir)
    tempDir = nil
    super.tearDown()
  }

  // MARK: - Tests

  func testFallthroughDisabled_noMatchStaysInGroup() {
    // Navigate into group "a"
    controller.handleKey("a", execute: true)
    XCTAssertEqual(userState.navigationPath.count, 1)
    XCTAssertEqual(userState.currentGroup?.key, "a")

    // Press "t" which only exists at root - fallthrough is OFF
    Defaults[.keyFallthroughEnabled] = false
    controller.handleKey("t", execute: false)

    // Should still be in group "a" (not found, no fallthrough)
    XCTAssertEqual(userState.navigationPath.count, 1)
    XCTAssertEqual(userState.currentGroup?.key, "a")
  }

  func testFallthroughEnabled_findsKeyAtRoot() {
    Defaults[.keyFallthroughEnabled] = true

    // Navigate into group "a"
    controller.handleKey("a", execute: true)
    XCTAssertEqual(userState.navigationPath.count, 1)
    XCTAssertEqual(userState.currentGroup?.key, "a")

    // Press "r" which is a group at root - should fall through and navigate into it
    controller.handleKey("r", execute: false)

    // Path should reset to root level then navigate into "r"
    XCTAssertEqual(userState.currentGroup?.key, "r")
    XCTAssertEqual(userState.navigationPath.count, 1)
  }

  func testFallthroughEnabled_walksUpFromGrandchild() {
    Defaults[.keyFallthroughEnabled] = true

    // Navigate into group "a" then "b" (2 levels deep)
    controller.handleKey("a", execute: true)
    controller.handleKey("b", execute: true)
    XCTAssertEqual(userState.navigationPath.count, 2)
    XCTAssertEqual(userState.currentGroup?.key, "b")

    // Press "t" which only exists at root
    controller.handleKey("t", execute: false)

    // Path should reset to root level (empty), no further navigation since "t" is an action
    XCTAssertEqual(userState.navigationPath.count, 0)
  }

  func testFallthroughEnabled_stopsAtFirstAncestorMatch() {
    Defaults[.keyFallthroughEnabled] = true

    // Navigate into group "a" then "b"
    controller.handleKey("a", execute: true)
    controller.handleKey("b", execute: true)
    XCTAssertEqual(userState.navigationPath.count, 2)

    // Press "x" which exists in parent group "a" (not root)
    controller.handleKey("x", execute: false)

    // Should match at parent "a" (index 0), path reset to [a]
    // "x" is an action so no further navigation
    XCTAssertEqual(userState.navigationPath.count, 1)
    XCTAssertEqual(userState.navigationPath.first?.key, "a")
  }

  func testFallthroughEnabled_navigatesIntoFallthroughGroup() {
    Defaults[.keyFallthroughEnabled] = true

    // Navigate into group "a" then "b"
    controller.handleKey("a", execute: true)
    controller.handleKey("b", execute: true)
    XCTAssertEqual(userState.navigationPath.count, 2)

    // Press "r" which is a group at root
    controller.handleKey("r", execute: false)

    // Should reset to root then navigate into "r"
    XCTAssertEqual(userState.currentGroup?.key, "r")
    XCTAssertEqual(userState.navigationPath.count, 1)
  }

  func testFallthroughEnabled_noMatchAnywhere() {
    Defaults[.keyFallthroughEnabled] = true

    // Navigate into group "a"
    controller.handleKey("a", execute: true)
    XCTAssertEqual(userState.navigationPath.count, 1)

    // Press "q" which doesn't exist anywhere
    controller.handleKey("q", execute: false)

    // Should still be in group "a" (not found)
    XCTAssertEqual(userState.navigationPath.count, 1)
    XCTAssertEqual(userState.currentGroup?.key, "a")
  }

  private func waitForConfigLoad() {
    let exp = expectation(description: "config load")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
    wait(for: [exp], timeout: 1.0)
  }

  func testFallthroughDisabled_atRootDoesNothing() {
    Defaults[.keyFallthroughEnabled] = true

    // At root, press a key that doesn't exist
    XCTAssertTrue(userState.navigationPath.isEmpty)
    controller.handleKey("q", execute: false)

    // Should stay at root (no crash, no fallthrough since already at root)
    XCTAssertTrue(userState.navigationPath.isEmpty)
  }
}
