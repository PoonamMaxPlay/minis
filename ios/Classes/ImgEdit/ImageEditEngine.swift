import Flutter
import Foundation
import ImageIO
import MetalKit
import UIKit

/// Per-viewId editor session — owns the [MTKView], the [LayerStack], and
/// the [HistoryStack]. Method calls arrive routed by viewId from
/// `ImageEditPluginRouter`.
///
/// Real Metal pipeline lives in `Metal/*.metal` shaders + a `pipeline.swift`
/// that orchestrates `MTLRenderCommandEncoder` passes. Until the shaders
/// land, rendering is a no-op and the surface presents the source image
/// via a `CALayer` placeholder.
public final class ImageEditEngine: NSObject {
    public let viewId: Int64
    let mtkView: MTKView
    private let layers = LayerStack()
    private let history = HistoryStack()
    private var sourcePath: String?
    private var width: Int = 0
    private var height: Int = 0
    private let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var renderer: ImageEditMetalRenderer?

    init(viewId: Int64, frame: CGRect, sourcePath: String?) {
        self.viewId = viewId
        self.mtkView = MTKView(frame: frame, device: device)
        self.sourcePath = sourcePath
        super.init()
        self.mtkView.framebufferOnly = false
        self.mtkView.colorPixelFormat = .bgra8Unorm
        self.mtkView.isPaused = true
        self.mtkView.enableSetNeedsDisplay = true
        if let device = device {
            let r = ImageEditMetalRenderer(device: device, viewId: viewId)
            r.hostView = self.mtkView
            self.renderer = r
            self.mtkView.delegate = r
        }
        if let path = sourcePath {
            renderer?.loadBaseImage(path: path)
        }
    }

    func detach() {
        renderer?.dispose()
        renderer = nil
        ImageEditPluginRouter.shared.unregister(viewId: viewId)
    }

    func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = (call.arguments as? [String: Any]) ?? [:]
        switch call.method {
        case "init":
            result(handleInit(args: args))
        case "dispose":
            detach()
            result(nil)
        case "pushLayer":
            let type = (args["type"] as? String) ?? "adjustment"
            let params = (args["params"] as? [String: Any]) ?? [:]
            let id = layers.push(type: type, params: params)
            history.recordPush(id: id, type: type, params: params)
            renderer?.setNeedsRender()
            result(["layerId": id])
        case "updateLayer":
            let id = (args["layerId"] as? Int) ?? -1
            let params = (args["params"] as? [String: Any]) ?? [:]
            let prev = layers.update(id: id, params: params)
            history.recordUpdate(id: id, prev: prev, next: params)
            renderer?.setNeedsRender()
            result(nil)
        case "removeLayer":
            let id = (args["layerId"] as? Int) ?? -1
            if let removed = layers.remove(id: id) {
                history.recordRemove(id: id, layer: removed)
            }
            renderer?.setNeedsRender()
            result(nil)
        case "reorderLayer":
            let id = (args["layerId"] as? Int) ?? -1
            let index = (args["index"] as? Int) ?? 0
            let from = layers.reorder(id: id, target: index)
            history.recordReorder(id: id, from: from, to: index)
            renderer?.setNeedsRender()
            result(nil)
        case "applyAdjust":
            let key = (args["key"] as? String) ?? ""
            let value = (args["value"] as? Double) ?? 0
            history.recordAdjust(key: key, prev: layers.currentAdjust(key), next: value)
            layers.applyAdjust(key: key, value: value)
            renderer?.applyAdjust(key: key, value: value)
            result(nil)
        case "applyFilter":
            let lutPath = (args["lutPath"] as? String) ?? ""
            let intensity = (args["intensity"] as? Double) ?? 1
            history.recordFilter(
                prevLut: layers.currentLut(),
                prevIntensity: layers.currentLutIntensity(),
                nextLut: lutPath,
                nextIntensity: intensity
            )
            layers.applyFilter(lutPath: lutPath, intensity: intensity)
            renderer?.applyFilter(lutPath: lutPath, intensity: intensity)
            result(nil)
        case "applyCrop":
            let rect = (args["rect"] as? [String: Any]) ?? [:]
            let rotation = (args["rotationDeg"] as? Double) ?? 0
            let persp = args["persp"] as? [Double]
            history.recordCrop(prev: layers.currentCrop(), rect: rect, rotationDeg: rotation, persp: persp)
            layers.applyCrop(rect: rect, rotationDeg: rotation, persp: persp)
            renderer?.applyCrop(rect: rect, rotationDeg: rotation, persp: persp)
            result(nil)
        case "brushStroke":
            renderer?.brushStroke(args: args)
            history.recordBlob(tag: "stroke", args: args)
            result(nil)
        case "spotHeal":
            renderer?.spotHeal(args: args)
            history.recordBlob(tag: "heal", args: args)
            result(nil)
        case "liquify":
            renderer?.liquify(args: args)
            history.recordBlob(tag: "liquify", args: args)
            result(nil)
        case "beautify":
            renderer?.beautify(args: args)
            history.recordBlob(tag: "beautify", args: args)
            result(nil)
        case "removeBg":
            var maskHandle = FaceDetector.runPersonSegmentation(
                viewId: viewId, sourcePath: sourcePath
            )
            if let dev = device, let path = sourcePath {
                let mask = BackgroundRemover.produceMaskTexture(
                    device: dev, sourcePath: path)
                if let tex = mask.texture {
                    renderer?.setMaskTexture(tex)
                    maskHandle["maskW"] = mask.width
                    maskHandle["maskH"] = mask.height
                    maskHandle["status"] = "ok"
                }
            }
            let id = layers.pushMask(maskHandle)
            history.recordPush(id: id, type: "mask", params: [:])
            result(["maskLayerId": id])
        case "placeText":
            let id = layers.push(type: "text", params: args)
            history.recordPush(id: id, type: "text", params: args)
            renderer?.setNeedsRender()
            result(["layerId": id])
        case "placeSticker":
            let id = layers.push(type: "sticker", params: args)
            history.recordPush(id: id, type: "sticker", params: args)
            renderer?.setNeedsRender()
            result(["layerId": id])
        case "placeEmoji":
            let id = layers.push(type: "emoji", params: args)
            history.recordPush(id: id, type: "emoji", params: args)
            renderer?.setNeedsRender()
            result(["layerId": id])
        case "undo":
            history.undo(into: layers)
            renderer?.setNeedsRender()
            result(["canUndo": history.canUndo, "canRedo": history.canRedo])
        case "redo":
            history.redo(into: layers)
            renderer?.setNeedsRender()
            result(["canUndo": history.canUndo, "canRedo": history.canRedo])
        case "setHistoryCap":
            let mb = (args["mb"] as? Int) ?? 64
            history.setMemoryCap(mb * 1024 * 1024)
            result(["capBytes": history.memoryCapBytes()])
        case "exportImage":
            let format = (args["format"] as? String) ?? "jpeg"
            let quality = (args["quality"] as? Int) ?? 92
            let maxDim = args["maxDim"] as? Int
            let path = (args["path"] as? String) ?? ""
            let res = Exporter.write(
                viewId: viewId,
                sourcePath: sourcePath,
                renderer: renderer,
                layers: layers,
                format: format,
                quality: quality,
                maxDim: maxDim,
                path: path
            )
            result(res)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleInit(args: [String: Any]) -> [String: Any] {
        let path = args["sourcePath"] as? String
        sourcePath = path
        let (w, h, exif) = decodeBounds(path: path)
        width = w
        height = h
        renderer?.initSession(sourcePath: path, width: w, height: h)
        layers.reset(width: w, height: h)
        history.clear()
        ImageEditPluginRouter.shared.notifyState(
            kind: "init",
            payload: ["viewId": viewId, "w": w, "h": h]
        )
        return [
            "viewId": viewId,
            "w": w,
            "h": h,
            "exif": exif,
        ]
    }

    private func decodeBounds(path: String?) -> (Int, Int, [String: Any]) {
        guard let path = path,
              let src = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, nil)
        else {
            return (0, 0, [:])
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
                as? [CFString: Any]
        else {
            return (0, 0, [:])
        }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        var exif: [String: Any] = [:]
        if let exifDict = props[kCGImagePropertyExifDictionary] as? [String: Any] {
            exif = exifDict
        }
        return (w, h, exif)
    }
}

private extension LayerStack {
    func currentAdjust(_ key: String) -> Double { adjustValue(forKey: key) }
}
