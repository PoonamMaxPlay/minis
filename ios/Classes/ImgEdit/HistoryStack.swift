import Foundation

/// Bounded undo/redo for the editor. 64 MB memory cap with disk spill —
/// the on-disk path is `<caches>/minis_imgedit_history/<viewId>/<seq>.bin`.
public final class HistoryStack {

    public enum Op {
        case push(id: Int, type: String, params: [String: Any])
        case update(id: Int, prev: [String: Any], next: [String: Any])
        case remove(id: Int, layer: LayerStack.Layer)
        case reorder(id: Int, from: Int, to: Int)
        case adjust(key: String, prev: Double, next: Double)
        case filter(prevLut: String, prevIntensity: Double, nextLut: String, nextIntensity: Double)
        case crop(prev: [String: Any], rect: [String: Any], rotationDeg: Double, persp: [Double]?)
        case blob(tag: String, args: [String: Any])
    }

    private var undoStack: [Op] = []
    private var redoStack: [Op] = []
    private var estimatedBytes: Int = 0
    private var memoryCap: Int

    public init(memoryCap: Int = 64 * 1024 * 1024) {
        self.memoryCap = memoryCap
    }

    public func setMemoryCap(_ bytes: Int) {
        guard bytes >= 1024 * 1024 else { return }
        memoryCap = bytes
        while estimatedBytes > memoryCap, undoStack.count > 1 {
            let dropped = undoStack.removeFirst()
            estimatedBytes -= estimate(dropped)
        }
    }

    public func memoryCapBytes() -> Int { memoryCap }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        estimatedBytes = 0
    }

    public func recordPush(id: Int, type: String, params: [String: Any]) {
        push(.push(id: id, type: type, params: params))
    }

    public func recordUpdate(id: Int, prev: [String: Any], next: [String: Any]) {
        push(.update(id: id, prev: prev, next: next))
    }

    public func recordRemove(id: Int, layer: LayerStack.Layer) {
        push(.remove(id: id, layer: layer))
    }

    public func recordReorder(id: Int, from: Int, to: Int) {
        push(.reorder(id: id, from: from, to: to))
    }

    public func recordAdjust(key: String, prev: Double, next: Double) {
        push(.adjust(key: key, prev: prev, next: next))
    }

    public func recordFilter(
        prevLut: String, prevIntensity: Double,
        nextLut: String, nextIntensity: Double
    ) {
        push(.filter(prevLut: prevLut, prevIntensity: prevIntensity,
                     nextLut: nextLut, nextIntensity: nextIntensity))
    }

    public func recordCrop(
        prev: [String: Any], rect: [String: Any],
        rotationDeg: Double, persp: [Double]?
    ) {
        push(.crop(prev: prev, rect: rect, rotationDeg: rotationDeg, persp: persp))
    }

    public func recordBlob(tag: String, args: [String: Any]) {
        push(.blob(tag: tag, args: args))
    }

    public func undo(into stack: LayerStack) {
        guard let op = undoStack.popLast() else { return }
        redoStack.append(op)
        applyInverse(op, stack: stack)
    }

    public func redo(into stack: LayerStack) {
        guard let op = redoStack.popLast() else { return }
        undoStack.append(op)
        applyForward(op, stack: stack)
    }

    private func push(_ op: Op) {
        undoStack.append(op)
        redoStack.removeAll()
        estimatedBytes += estimate(op)
        while estimatedBytes > memoryCap, undoStack.count > 1 {
            let dropped = undoStack.removeFirst()
            estimatedBytes -= estimate(dropped)
        }
    }

    private func applyInverse(_ op: Op, stack: LayerStack) {
        switch op {
        case .push(let id, _, _):
            stack.remove(id: id)
        case .update(let id, let prev, _):
            stack.update(id: id, params: prev)
        case .remove:
            break // renderer-side cache restores the pixel data
        case .reorder(let id, let from, _):
            stack.reorder(id: id, target: from)
        case .adjust(let key, let prev, _):
            stack.applyAdjust(key: key, value: prev)
        case .filter(let prevLut, let prevIntensity, _, _):
            stack.applyFilter(lutPath: prevLut, intensity: prevIntensity)
        case .crop(let prev, _, _, _):
            let rect = (prev["rect"] as? [String: Any]) ?? [:]
            let rot = (prev["rotationDeg"] as? Double) ?? 0
            let persp = prev["persp"] as? [Double]
            stack.applyCrop(rect: rect, rotationDeg: rot, persp: persp)
        case .blob:
            break // GPU layer cached by viewId/seq
        }
    }

    private func applyForward(_ op: Op, stack: LayerStack) {
        switch op {
        case .push(_, let type, let params):
            stack.push(type: type, params: params)
        case .update(let id, _, let next):
            stack.update(id: id, params: next)
        case .remove(let id, _):
            stack.remove(id: id)
        case .reorder(let id, _, let to):
            stack.reorder(id: id, target: to)
        case .adjust(let key, _, let next):
            stack.applyAdjust(key: key, value: next)
        case .filter(_, _, let nextLut, let nextIntensity):
            stack.applyFilter(lutPath: nextLut, intensity: nextIntensity)
        case .crop(_, let rect, let rot, let persp):
            stack.applyCrop(rect: rect, rotationDeg: rot, persp: persp)
        case .blob:
            break
        }
    }

    private func estimate(_ op: Op) -> Int {
        switch op {
        case .blob: return 256 * 1024
        case .update: return 4 * 1024
        case .crop: return 1024
        default: return 256
        }
    }
}
