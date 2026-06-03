import Flutter
import UIKit

/// `loopit/minis/audio/waveform` PlatformView. Renders peaks[] as vertical bars
/// with a progress overlay. Live mode appends a fresh peak per `appendLive`
/// call and scrolls left.
public final class MinisWaveformViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    public func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        let params = (args as? [String: Any]) ?? [:]
        return MinisWaveformPlatformView(
            frame: frame,
            viewId: viewId,
            args: params,
            messenger: messenger
        )
    }

    public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

final class MinisWaveformPlatformView: NSObject, FlutterPlatformView {
    private let waveform: MinisWaveformDrawable
    private let channel: FlutterMethodChannel

    init(
        frame: CGRect,
        viewId: Int64,
        args: [String: Any],
        messenger: FlutterBinaryMessenger
    ) {
        waveform = MinisWaveformDrawable(frame: frame)
        channel = FlutterMethodChannel(
            name: "loopit/minis/audio/waveform/\(viewId)",
            binaryMessenger: messenger
        )
        super.init()
        waveform.apply(args: args)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(nil); return }
            switch call.method {
            case "update":
                if let m = call.arguments as? [String: Any] {
                    DispatchQueue.main.async { self.waveform.apply(args: m) }
                }
                result(nil)
            case "appendLive":
                if let p = call.arguments as? NSNumber {
                    DispatchQueue.main.async { self.waveform.pushLive(p.doubleValue) }
                }
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    public func view() -> UIView { waveform }

    deinit {
        channel.setMethodCallHandler(nil)
    }
}

final class MinisWaveformDrawable: UIView {
    private var peaks: [Double] = []
    private var live: Bool = false
    private var barColor: UIColor = .white
    private var bgColor: UIColor = .clear
    private var progressColor: UIColor = UIColor(red: 1.0, green: 0.2, blue: 0.4, alpha: 1.0)
    private var progressMs: Int = 0
    private var durationMs: Int = 0
    private var barWidth: CGFloat = 2.0
    private var barGap: CGFloat = 1.5
    private var livePeaks: [Double] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    func apply(args: [String: Any]) {
        if let p = args["peaks"] as? [NSNumber] {
            peaks = p.map { $0.doubleValue }
        }
        if let c = args["color"] as? NSNumber { barColor = MinisWaveformDrawable.color(c.intValue) }
        if let c = args["bgColor"] as? NSNumber {
            bgColor = MinisWaveformDrawable.color(c.intValue)
            backgroundColor = bgColor
        }
        if let c = args["progressColor"] as? NSNumber {
            progressColor = MinisWaveformDrawable.color(c.intValue)
        }
        if let v = args["progressMs"] as? NSNumber { progressMs = v.intValue }
        if let v = args["durationMs"] as? NSNumber { durationMs = v.intValue }
        if let v = args["barWidthDp"] as? NSNumber { barWidth = CGFloat(v.doubleValue) }
        if let v = args["barGapDp"] as? NSNumber { barGap = CGFloat(v.doubleValue) }
        if let v = args["mode"] as? String { live = v == "live" }
        setNeedsDisplay()
    }

    func pushLive(_ p: Double) {
        livePeaks.append(min(1.0, max(0.0, p)))
        let step = max(CGFloat(1), barWidth + barGap)
        let maxBars = Int(bounds.width / step)
        if maxBars > 0 && livePeaks.count > maxBars {
            livePeaks.removeFirst(livePeaks.count - maxBars)
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let step = max(CGFloat(1), barWidth + barGap)
        let barCount = max(1, Int(bounds.width / step))
        let data = live ? livePeaks : peaks
        if data.isEmpty { return }
        let midY = bounds.height / 2
        let progressFrac: CGFloat = (durationMs > 0)
            ? CGFloat(min(max(progressMs, 0), durationMs)) / CGFloat(durationMs)
            : 0
        let progressBar = Int(CGFloat(barCount) * progressFrac)
        for i in 0..<barCount {
            let srcIdx = min(data.count - 1, Int(Int64(i) * Int64(data.count) / Int64(barCount)))
            let mag = CGFloat(min(1.0, max(0.0, data[srcIdx])))
            let h = mag * bounds.height * 0.5
            let x = CGFloat(i) * step
            let color = (i < progressBar) ? progressColor : barColor
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: x, y: midY - h, width: barWidth, height: h * 2))
        }
    }

    static func color(_ argb: Int) -> UIColor {
        let a = CGFloat((argb >> 24) & 0xFF) / 255.0
        let r = CGFloat((argb >> 16) & 0xFF) / 255.0
        let g = CGFloat((argb >> 8) & 0xFF) / 255.0
        let b = CGFloat(argb & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: a == 0 ? 1 : a)
    }
}
