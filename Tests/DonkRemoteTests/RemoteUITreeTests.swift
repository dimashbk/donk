import DonkCore
import DonkUI
import UIKit
import XCTest
@testable import DonkRemote

final class LoginController: UIViewController {}

final class DonkProbeWindow: UIWindow {}

struct FakeUIProvider: RemoteUIProvider, @unchecked Sendable {
    let windows: [UIWindow]
    let keyWindow: UIWindow?

    @MainActor func hasForegroundScene() -> Bool { true }

    @MainActor func tree(_ options: RemoteTreeOptions) throws -> JSONValue {
        RemoteUITree.document(windows: windows, keyWindow: keyWindow, screen: UIScreen.main, options: options)
    }

    @MainActor func screenshot(scale: CGFloat) throws -> CGImage {
        try LiveUIProvider.composite(windows, screen: UIScreen.main, scale: scale)
    }
}

@MainActor
final class RemoteUITreeTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var appWindow: UIWindow!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { build() }
    }

    override func tearDown() async throws {
        await MainActor.run {
            windows.forEach { $0.isHidden = true }
            windows = []
            appWindow = nil
        }
        try await super.tearDown()
    }

    private func build() {
        let bounds = UIScreen.main.bounds
        let window = UIWindow(frame: bounds)
        let controller = LoginController()
        controller.title = "Login"
        window.rootViewController = controller
        let root = controller.view!
        root.frame = bounds

        let title = UILabel(frame: CGRect(x: 16, y: 100, width: 200, height: 30))
        title.text = "Войти"
        title.accessibilityIdentifier = "title.label"
        title.accessibilityLabel = "Sign in title"
        title.accessibilityTraits = .header
        root.addSubview(title)

        let button = UIButton(type: .system)
        button.frame = CGRect(x: 16, y: 620, width: 343, height: 52)
        button.setTitle("Войти", for: .normal)
        button.accessibilityIdentifier = "login.button"
        button.accessibilityTraits = [.button, .selected]
        root.addSubview(button)

        let password = UITextField(frame: CGRect(x: 16, y: 200, width: 300, height: 44))
        password.isSecureTextEntry = true
        password.text = "hunter2"
        password.accessibilityIdentifier = "password.field"
        root.addSubview(password)

        let email = UITextField(frame: CGRect(x: 16, y: 260, width: 300, height: 44))
        email.placeholder = "Email"
        email.accessibilityIdentifier = "email.field"
        root.addSubview(email)

        let hidden = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        hidden.isHidden = true
        hidden.accessibilityIdentifier = "hidden.view"
        let hiddenChild = UIView(frame: .zero)
        hiddenChild.accessibilityIdentifier = "hidden.child"
        hidden.addSubview(hiddenChild)
        root.addSubview(hidden)

        let transparent = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        transparent.alpha = 0
        transparent.accessibilityIdentifier = "transparent.view"
        root.addSubview(transparent)

        let tappable = UIView(frame: CGRect(x: 20, y: 400, width: 100, height: 40))
        tappable.accessibilityIdentifier = "tappable.view"
        tappable.addGestureRecognizer(UITapGestureRecognizer())
        let inner = UIView(frame: CGRect(x: 5, y: 5, width: 10, height: 10))
        inner.accessibilityIdentifier = "inner.view"
        tappable.addSubview(inner)
        root.addSubview(tappable)

        window.isHidden = false

        let donk = DonkProbeWindow(frame: bounds)
        donk.isHidden = false
        let overlay = UIWindow(frame: bounds)
        overlay.windowLevel = DonkWindowLevel.inspector
        overlay.isHidden = false
        let hiddenWindow = UIWindow(frame: bounds)
        let alert = UIWindow(frame: bounds)
        alert.windowLevel = .alert
        alert.alpha = 0
        alert.isHidden = false

        appWindow = window
        windows = [window, donk, overlay, hiddenWindow, alert]
    }

    private func tree(_ options: RemoteTreeOptions = RemoteTreeOptions()) -> JSONValue {
        RemoteUITree.document(windows: windows, keyWindow: appWindow, screen: UIScreen.main, options: options)
    }

    private func node(_ tree: JSONValue, id: String) -> JSONValue? {
        if tree["id"]?.string == id { return tree }
        for key in ["windows", "root", "children"] {
            if let value = tree[key] {
                let candidates = value.array ?? [value]
                for candidate in candidates {
                    if let found = node(candidate, id: id) { return found }
                }
            }
        }
        return nil
    }

    private func controllerRoot(_ tree: JSONValue) -> JSONValue? {
        if tree["viewController"] != nil { return tree }
        for key in ["windows", "root", "children"] {
            if let value = tree[key] {
                for candidate in value.array ?? [value] {
                    if let found = controllerRoot(candidate) { return found }
                }
            }
        }
        return nil
    }

    private func depth(of view: UIView) -> Int {
        var depth = 0
        var current = view.superview
        while let next = current {
            depth += 1
            current = next.superview
        }
        return depth
    }

    func testDocumentShape() throws {
        let document = tree()
        XCTAssertEqual(document.keys, ["screen", "topViewController", "controllers", "windows", "nodeCount", "truncated"])
        XCTAssertEqual(document["screen"]?["width"]?.double, Double(UIScreen.main.bounds.width))
        XCTAssertEqual(document["screen"]?["scale"]?.double, Double(UIScreen.main.scale))
        XCTAssertEqual(document["topViewController"]?.string, "LoginController")
        XCTAssertEqual(document["controllers"]?["class"]?.string, "LoginController")
        XCTAssertEqual(document["controllers"]?["title"]?.string, "Login")
        XCTAssertEqual(document["truncated"]?.bool, false)
        let windows = try XCTUnwrap(document["windows"]?.array)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].keys, ["class", "frame", "level", "isKey", "root"])
        XCTAssertEqual(windows[0]["class"]?.string, "UIWindow")
        XCTAssertEqual(windows[0]["level"]?.double, 0)
        XCTAssertEqual(windows[0]["root"]?["class"]?.string, "UIWindow")
        XCTAssertEqual(controllerRoot(document)?["viewController"]?.string, "LoginController")
        XCTAssertGreaterThanOrEqual(document["nodeCount"]?.int ?? 0, 8)
    }

    func testNodeFields() throws {
        let document = tree()
        let label = try XCTUnwrap(node(document, id: "title.label"))
        XCTAssertEqual(label["class"]?.string, "UILabel")
        XCTAssertEqual(label["text"]?.string, "Войти")
        XCTAssertEqual(label["label"]?.string, "Sign in title")
        XCTAssertEqual(label["frame"], .object([
            JSONMember(key: "x", value: .number("16")),
            JSONMember(key: "y", value: .number("100")),
            JSONMember(key: "width", value: .number("200")),
            JSONMember(key: "height", value: .number("30")),
        ]))
        XCTAssertEqual(label["traits"], .array([.string("header")]))
        XCTAssertEqual(label["interactive"]?.bool, false)
        XCTAssertEqual(label["hidden"]?.bool, false)
        XCTAssertEqual(label["alpha"]?.double, 1)
        XCTAssertNil(label["children"])

        let button = try XCTUnwrap(node(document, id: "login.button"))
        XCTAssertEqual(button["class"]?.string, "UIButton")
        XCTAssertEqual(button["text"]?.string, "Войти")
        XCTAssertEqual(button["interactive"]?.bool, true)
        XCTAssertEqual(button["traits"], .array([.string("button"), .string("selected")]))

        let password = try XCTUnwrap(node(document, id: "password.field"))
        XCTAssertEqual(password["text"]?.string, "••••")
        XCTAssertFalse(document.compact().contains("hunter2"))
        if let value = password["value"]?.string {
            XCTAssertEqual(value, "••••")
        }

        let email = try XCTUnwrap(node(document, id: "email.field"))
        XCTAssertEqual(email["text"]?.string, "Email")
        XCTAssertEqual(email["placeholder"]?.bool, true)
        XCTAssertNil(password["placeholder"])

        let tappable = try XCTUnwrap(node(document, id: "tappable.view"))
        XCTAssertEqual(tappable["interactive"]?.bool, true)
        XCTAssertEqual(tappable["children"]?[0]?["id"]?.string, "inner.view")
        XCTAssertEqual(tappable["children"]?[0]?["frame"]?["x"]?.double, 25)
    }

    func testHiddenViewsAreSkippedUnlessRequested() throws {
        let visible = tree()
        XCTAssertNil(node(visible, id: "hidden.view"))
        XCTAssertNil(node(visible, id: "hidden.child"))
        XCTAssertNil(node(visible, id: "transparent.view"))
        var options = RemoteTreeOptions()
        options.includeHidden = true
        let all = tree(options)
        XCTAssertEqual(node(all, id: "hidden.view")?["hidden"]?.bool, true)
        XCTAssertNotNil(node(all, id: "hidden.child"))
        XCTAssertEqual(node(all, id: "transparent.view")?["hidden"]?.bool, true)
        XCTAssertEqual(node(all, id: "transparent.view")?["alpha"]?.double, 0)
        XCTAssertGreaterThan(all["nodeCount"]?.int ?? 0, visible["nodeCount"]?.int ?? 0)
    }

    func testMaxDepthOmitsChildren() throws {
        let rootView = try XCTUnwrap(appWindow.rootViewController?.view)
        var options = RemoteTreeOptions()
        options.maxDepth = depth(of: rootView)
        let document = tree(options)
        let root = try XCTUnwrap(controllerRoot(document))
        XCTAssertEqual(root["viewController"]?.string, "LoginController")
        XCTAssertNil(root["children"])
        XCTAssertEqual(root["childrenOmitted"]?.int, 5)
        XCTAssertEqual(document["nodeCount"]?.int, options.maxDepth + 1)
        XCTAssertEqual(document["truncated"]?.bool, false)
        options.maxDepth = 0
        let shallow = tree(options)
        XCTAssertEqual(shallow["nodeCount"]?.int, 1)
        XCTAssertNotNil(shallow["windows"]?[0]?["root"]?["childrenOmitted"])
    }

    func testMaxNodesTruncates() {
        var options = RemoteTreeOptions()
        options.maxNodes = 3
        let document = tree(options)
        XCTAssertEqual(document["nodeCount"]?.int, 3)
        XCTAssertEqual(document["truncated"]?.bool, true)
    }

    func testDonkHiddenAndTransparentWindowsAreExcluded() {
        let included = RemoteUITree.includedWindows(windows)
        XCTAssertEqual(included, [appWindow])
    }

    func testControllerTree() {
        let navigation = UINavigationController(rootViewController: LoginController())
        navigation.viewControllers[0].title = "First"
        let second = LoginController()
        navigation.pushViewController(second, animated: false)
        let tabs = UITabBarController()
        tabs.viewControllers = [navigation, UIViewController()]
        tabs.selectedIndex = 0
        XCTAssertTrue(RemoteUITree.topViewController(from: tabs) === second)
        var budget = 100
        let node = RemoteUITree.controllerNode(tabs, depth: 0, budget: &budget)
        XCTAssertEqual(node["class"]?.string, "UITabBarController")
        XCTAssertEqual(node["children"]?[0]?["class"]?.string, "UINavigationController")
        XCTAssertEqual(node["children"]?[0]?["children"]?[0]?["title"]?.string, "First")
        XCTAssertEqual(node["children"]?[0]?["children"]?.array?.count, 2)
    }

    func testTraitNames() {
        XCTAssertEqual(RemoteTraits.names([.button, .selected]), ["button", "selected"])
        XCTAssertTrue(RemoteTraits.isInteractive(.link))
        XCTAssertFalse(RemoteTraits.isInteractive([.button, .notEnabled]))
        XCTAssertFalse(RemoteTraits.isInteractive(.staticText))
    }

    func testTreeAndScreenshotThroughHandler() async throws {
        var fixture = RemoteFixture()
        fixture.ui = FakeUIProvider(windows: windows, keyWindow: appWindow)
        let handler = fixture.handler
        let tree = try await call(handler, "ui.tree", #"{"maxDepth":2,"maxNodes":5000}"#)
        XCTAssertEqual(tree["windows"]?.array?.count, 1)
        let shot = try await call(handler, "ui.screenshot", #"{"scale":0.5,"format":"png"}"#)
        XCTAssertEqual(shot["mimeType"]?.string, "image/png")
        XCTAssertEqual(shot["width"]?.int, Int((UIScreen.main.bounds.width * 0.5).rounded()))
        XCTAssertEqual(shot["height"]?.int, Int((UIScreen.main.bounds.height * 0.5).rounded()))
        let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(shot["data"]?.string)))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let jpeg = try await call(handler, "ui.screenshot", #"{"scale":10}"#)
        XCTAssertEqual(jpeg["mimeType"]?.string, "image/jpeg")
        XCTAssertEqual(jpeg["width"]?.int, Int((UIScreen.main.bounds.width * 3).rounded()))
        let jpegData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(jpeg["data"]?.string)))
        XCTAssertEqual(Array(jpegData.prefix(3)), [0xFF, 0xD8, 0xFF])
    }

    func testScreenshotFailsWithoutWindows() {
        XCTAssertThrowsError(try LiveUIProvider.composite([], screen: UIScreen.main, scale: 1)) { error in
            XCTAssertEqual((error as? RemoteError)?.code, -32001)
        }
    }
}
