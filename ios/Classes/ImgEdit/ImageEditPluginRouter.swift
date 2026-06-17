import Flutter
import Foundation
import UIKit

/// Single shared MethodChannel + EventChannel for the image editor.
/// Every Dart call carries a `viewId`; the router dispatches it to the
/// matching `ImageEditEngine`. Mirrors `ImageEditPluginRouter.kt`.
public final class ImageEditPluginRouter: NSObject {
    public static let shared = ImageEditPluginRouter()

    public static let methodChannelName = "loopit/minis/imgedit"
    public static let eventChannelName = "loopit/minis/imgedit/state"
    public static let platformViewType = "loopit/minis/imgedit/canvas"

    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?
    private var engines: [Int64: ImageEditEngine] = [:]

    public func attach(messenger: FlutterBinaryMessenger) {
        guard methodChannel == nil else { return }
        let mc = FlutterMethodChannel(
            name: ImageEditPluginRouter.methodChannelName,
            binaryMessenger: messenger
        )
        mc.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
        methodChannel = mc

        let ec = FlutterEventChannel(
            name: ImageEditPluginRouter.eventChannelName,
            binaryMessenger: messenger
        )
        ec.setStreamHandler(EventStream { [weak self] sink in
            self?.eventSink = sink
        })
        eventChannel = ec
    }

    public func detach() {
        methodChannel?.setMethodCallHandler(nil)
        methodChannel = nil
        eventChannel?.setStreamHandler(nil)
        eventChannel = nil
        eventSink = nil
        for engine in engines.values { engine.detach() }
        engines.removeAll()
    }

    func register(_ engine: ImageEditEngine) {
        engines[engine.viewId] = engine
    }

    func unregister(viewId: Int64) {
        engines.removeValue(forKey: viewId)
    }

    func notifyState(kind: String, payload: [String: Any]) {
        guard let sink = eventSink else { return }
        var event = payload
        event["kind"] = kind
        sink(event)
    }

    public func notifyRenderProgress(viewId: Int64, pct: Double) {
        notifyState(kind: "renderProgress", payload: ["viewId": viewId, "pct": pct])
    }

    public func notifyError(viewId: Int64, code: String, message: String) {
        notifyState(kind: "error",
                    payload: ["viewId": viewId, "code": code, "message": message])
    }

    public func notifyMemoryPressure(viewId: Int64?, levelMb: Int) {
        var payload: [String: Any] = ["levelMb": levelMb]
        if let id = viewId { payload["viewId"] = id }
        notifyState(kind: "memoryPressure", payload: payload)
    }

    private var memoryObserver: NSObjectProtocol?

    public func observeMemoryWarnings() {
        let center = NotificationCenter.default
        memoryObserver = center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.notifyMemoryPressure(viewId: nil, levelMb: 0)
        }
    }

    public func stopObservingMemoryWarnings() {
        if let obs = memoryObserver {
            NotificationCenter.default.removeObserver(obs)
            memoryObserver = nil
        }
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "listFilters":
            result(["filters": AssetCatalog.filters()])
            return
        case "listStickerPacks":
            result(["packs": AssetCatalog.stickerPacks()])
            return
        case "listFonts":
            result(["fonts": AssetCatalog.fonts()])
            return
        default:
            break
        }

        let args = (call.arguments as? [String: Any]) ?? [:]
        let viewId: Int64
        if let raw = args["viewId"] as? NSNumber {
            viewId = raw.int64Value
        } else {
            viewId = engines.keys.first ?? -1
        }
        guard let engine = engines[viewId] else {
            result([:])
            return
        }
        engine.handle(call: call, result: result)
    }
}

private final class EventStream: NSObject, FlutterStreamHandler {
    let onListen: (FlutterEventSink?) -> Void

    init(onListen: @escaping (FlutterEventSink?) -> Void) {
        self.onListen = onListen
    }

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        onListen(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        onListen(nil)
        return nil
    }
}
