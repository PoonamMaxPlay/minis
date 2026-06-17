import Foundation

/// Minis iOS camera state machine, mirroring the Android version.
public enum MinisCameraState: String {
    case idle, preview, recording, paused, stopped, finalized, error
}

public protocol MinisCameraSessionListener: AnyObject {
    func cameraSessionDidTransition(
        from prev: MinisCameraState,
        to next: MinisCameraState,
        code: String?,
        message: String?
    )
}

public final class MinisCameraSessionMachine {
    public private(set) var state: MinisCameraState = .idle
    public weak var listener: MinisCameraSessionListener?
    private let queue = DispatchQueue(label: "minis.camera.session")

    public init() {}

    @discardableResult
    public func transition(to next: MinisCameraState, code: String? = nil, message: String? = nil) -> Bool {
        var ok = false
        queue.sync {
            if isLegal(prev: state, next: next) {
                let prev = state
                state = next
                ok = true
                listener?.cameraSessionDidTransition(from: prev, to: next, code: code, message: message)
            }
        }
        return ok
    }

    public func error(code: String, message: String?) {
        queue.sync {
            let prev = state
            state = .error
            listener?.cameraSessionDidTransition(from: prev, to: .error, code: code, message: message)
        }
    }

    private func isLegal(prev: MinisCameraState, next: MinisCameraState) -> Bool {
        switch prev {
        case .idle: return next == .preview || next == .error
        case .preview: return next == .recording || next == .idle || next == .error
        case .recording: return next == .paused || next == .stopped || next == .error
        case .paused: return next == .recording || next == .stopped || next == .error
        case .stopped: return next == .finalized || next == .preview || next == .error
        case .finalized: return next == .preview || next == .idle
        case .error: return next == .idle || next == .preview
        }
    }
}
