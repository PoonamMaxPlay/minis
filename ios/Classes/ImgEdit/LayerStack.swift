import Foundation

/// Mirrors `LayerStack.kt` and the layer model in improvement2.md.
public final class LayerStack {

    public enum Kind: String {
        case baseImage
        case adjustment
        case filter
        case sticker
        case text
        case draw
        case mask
        case emoji
    }

    public struct Layer {
        public let id: Int
        public let kind: Kind
        public var params: [String: Any]
        public var visible: Bool
        public var opacity: Double
        public var blend: String
    }

    private static var nextId: Int = 1
    private(set) var items: [Layer] = []
    private var adjust: [String: Double] = [:]
    private(set) var lutPath: String = ""
    private(set) var lutIntensity: Double = 0
    private(set) var crop: [String: Any] = [:]
    private(set) var width: Int = 0
    private(set) var height: Int = 0

    public func reset(width: Int, height: Int) {
        self.width = width
        self.height = height
        items.removeAll()
        adjust.removeAll()
        lutPath = ""
        lutIntensity = 0
        crop = [:]
        items.append(Layer(
            id: nextLayerId(),
            kind: .baseImage,
            params: [:],
            visible: true,
            opacity: 1,
            blend: "normal"
        ))
    }

    @discardableResult
    public func push(type: String, params: [String: Any]) -> Int {
        let kind = parseKind(type)
        let layer = Layer(
            id: nextLayerId(),
            kind: kind,
            params: params,
            visible: true,
            opacity: 1,
            blend: "normal"
        )
        items.append(layer)
        return layer.id
    }

    @discardableResult
    public func pushMask(_ payload: [String: Any]) -> Int {
        let layer = Layer(
            id: nextLayerId(),
            kind: .mask,
            params: payload,
            visible: true,
            opacity: 1,
            blend: "normal"
        )
        items.append(layer)
        return layer.id
    }

    @discardableResult
    public func update(id: Int, params: [String: Any]) -> [String: Any] {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return [:] }
        let prev = items[idx].params
        items[idx].params = params
        return prev
    }

    @discardableResult
    public func remove(id: Int) -> Layer? {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: idx)
    }

    @discardableResult
    public func reorder(id: Int, target: Int) -> Int {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return -1 }
        let layer = items.remove(at: from)
        let clamped = max(0, min(items.count, target))
        items.insert(layer, at: clamped)
        return from
    }

    public func applyAdjust(key: String, value: Double) {
        adjust[key] = value
    }

    public func applyFilter(lutPath: String, intensity: Double) {
        self.lutPath = lutPath
        self.lutIntensity = intensity
    }

    public func applyCrop(rect: [String: Any], rotationDeg: Double, persp: [Double]?) {
        crop = [
            "rect": rect,
            "rotationDeg": rotationDeg,
            "persp": persp ?? [],
        ]
    }

    public func adjustValue(forKey key: String) -> Double {
        return adjust[key] ?? 0
    }

    public func currentLut() -> String { lutPath }
    public func currentLutIntensity() -> Double { lutIntensity }
    public func currentCrop() -> [String: Any] { crop }

    public func snapshot() -> Snapshot {
        Snapshot(
            layers: items,
            adjust: adjust,
            lutPath: lutPath,
            lutIntensity: lutIntensity,
            crop: crop
        )
    }

    public func restore(_ snapshot: Snapshot) {
        items = snapshot.layers
        adjust = snapshot.adjust
        lutPath = snapshot.lutPath
        lutIntensity = snapshot.lutIntensity
        crop = snapshot.crop
    }

    public struct Snapshot {
        public let layers: [Layer]
        public let adjust: [String: Double]
        public let lutPath: String
        public let lutIntensity: Double
        public let crop: [String: Any]
    }

    private func nextLayerId() -> Int {
        LayerStack.nextId += 1
        return LayerStack.nextId
    }

    private func parseKind(_ wire: String) -> Kind {
        return Kind(rawValue: wire) ?? .adjustment
    }
}
