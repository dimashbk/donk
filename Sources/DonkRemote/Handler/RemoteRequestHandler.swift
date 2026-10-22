import DonkCore
import Foundation
import UIKit

final class RemoteRequestHandler: Sendable {
    let context: RemoteContext

    init(context: RemoteContext) {
        self.context = context
    }

    func handle(_ text: String) async -> String? {
        switch RemoteIncoming.parse(text) {
        case let .request(id, method, params):
            return await respond(id: id, method: method, params: params)
        case let .invalid(id):
            return RemoteFrame.error(id: id, .invalidRequest())
        case .notification, .response:
            return nil
        }
    }

    func respond(id: JSONValue, method: String, params: JSONValue?) async -> String {
        let frame: String
        do {
            frame = RemoteFrame.result(id: id, try await result(method: method, params: params))
        } catch let error as RemoteError {
            return RemoteFrame.error(id: id, error)
        } catch {
            return RemoteFrame.error(id: id, .unavailable(String(describing: error)))
        }
        guard frame.utf8.count <= context.maxFrameBytes else {
            let limit = context.maxFrameBytes / (1024 * 1024)
            return RemoteFrame.error(id: id, .unavailable("result is larger than \(limit) MB; lower maxBodyBytes, maxMessages, maxNodes or scale"))
        }
        return frame
    }

    func result(method: String, params: JSONValue?) async throws -> JSONValue {
        switch method {
        case "app.info":
            _ = try RemoteParams(params)
            return appInfo()
        case "network.list":
            return try RemoteNetwork.list(RemoteParams(params), context: context)
        case "network.get":
            return try RemoteNetwork.get(RemoteParams(params), context: context)
        case "crashes.list":
            return try RemoteCrashes.list(RemoteParams(params), context: context)
        case "crashes.get":
            return try RemoteCrashes.get(RemoteParams(params), context: context)
        case "ui.tree":
            return try await tree(RemoteParams(params))
        case "ui.screenshot":
            return try await screenshot(RemoteParams(params))
        default:
            throw RemoteError.methodNotFound(method)
        }
    }

    // MARK: - app.info

    func appInfo() -> JSONValue {
        let store = context.store
        var network = RemoteObject()
        network.set("captureEnabled", store.isCaptureEnabled)
        network.set("entries", store.count)
        network.set("totalBytes", store.totalBytes)
        network.set("limit", store.limit)

        var rules = RemoteObject()
        rules.set("enabled", context.rules.isEnabled)
        rules.set("active", context.rules.rules.filter(\.isEnabled).count)

        var object = RemoteObject()
        object.set("app", context.identity.appJSON)
        object.set("device", context.identity.device.json)
        object.set("donkVersion", context.identity.donkVersion)
        object.set("session", context.identity.session.uuidString)
        object.set("uptimeSec", number: max(0, context.now().timeIntervalSince(context.launchDate)), decimals: 1)
        object.set("network", network.value)
        object.set("rules", rules.value)
        if let crashes = context.crashes {
            var value = RemoteObject()
            let installed = crashes.isInstalled
            value.set("installed", installed)
            value.set("reports", installed ? crashes.reports().count : 0)
            object.set("crashes", value.value)
        }
        return object.value
    }

    // MARK: - ui

    private func tree(_ params: RemoteParams) async throws -> JSONValue {
        var options = RemoteTreeOptions()
        options.maxDepth = try params.clamped("maxDepth", default: options.maxDepth, range: 0...256)
        options.includeHidden = try params.bool("includeHidden") ?? false
        options.maxNodes = try params.clamped("maxNodes", default: options.maxNodes, range: 1...20000)
        let provider = try uiProvider()
        return try await provider.tree(options)
    }

    private func screenshot(_ params: RemoteParams) async throws -> JSONValue {
        let scale = min(3, max(0.25, try params.number("scale") ?? 1))
        let format = try params.string("format") ?? "jpeg"
        guard format == "jpeg" || format == "png" else {
            throw RemoteError.invalidParams("format must be jpeg or png")
        }
        let quality = min(1, max(0, try params.number("quality") ?? 0.7))
        let provider = try uiProvider()
        let image = try await provider.screenshot(scale: CGFloat(scale))
        let encoded = format == "png"
            ? UIImage(cgImage: image).pngData()
            : UIImage(cgImage: image).jpegData(compressionQuality: CGFloat(quality))
        guard let data = encoded else {
            throw RemoteError.unavailable("snapshot encoding failed")
        }
        var object = RemoteObject()
        object.set("mimeType", format == "png" ? "image/png" : "image/jpeg")
        object.set("width", image.width)
        object.set("height", image.height)
        object.set("data", data.base64EncodedString())
        return object.value
    }

    private func uiProvider() throws -> RemoteUIProvider {
        guard let provider = context.ui else {
            throw RemoteError.unavailable("UI inspection is not available")
        }
        return provider
    }
}
