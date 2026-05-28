import Flutter
import UIKit
import AVFoundation

public class MinisPreviewPlayerFactory: NSObject, FlutterPlatformViewFactory {
    private var messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    public func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        return MinisPreviewPlayer(
            frame: frame,
            viewIdentifier: viewId,
            arguments: args,
            messenger: messenger)
    }
    
    public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

class MinisVideoView: UIView {
    var playerLayer: AVPlayerLayer? {
        didSet {
            if let layer = playerLayer {
                layer.frame = self.bounds
                self.layer.addSublayer(layer)
            }
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = self.bounds
    }
}

public class MinisPreviewPlayer: NSObject, FlutterPlatformView {
    private let videoView: MinisVideoView
    private let playerLayer: AVPlayerLayer
    private var player: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private let channel: FlutterMethodChannel
    private var mute: Bool = false

    // Store original durations
    private var totalDurationMs: Int = 0
    private var videoSize: CGSize = .zero
    
    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        messenger: FlutterBinaryMessenger
    ) {
        videoView = MinisVideoView(frame: frame)
        videoView.backgroundColor = .black
        playerLayer = AVPlayerLayer()
        videoView.playerLayer = playerLayer
        
        channel = FlutterMethodChannel(name: "minis_preview_player_\(viewId)", binaryMessenger: messenger)
        
        super.init()
        
        channel.setMethodCallHandler { [weak self] (call, result) in
            self?.handleMethodCall(call, result: result)
        }
        
        if let argsDict = args as? [String: Any] {
            self.mute = (argsDict["mute"] as? Bool) ?? false
            if let paths = argsDict["paths"] as? [String] {
                setupPlayer(paths: paths)
            }
        }
    }
    
    private func setupPlayer(paths: [String]) {
        Task {
            let composition = AVMutableComposition()
            var insertTime = CMTime.zero
            
            guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return
            }
            
            for path in paths {
                let url = URL(fileURLWithPath: path)
                let asset = AVURLAsset(url: url)
                
                let duration: CMTime
                if #available(iOS 15.0, *) {
                    duration = try await asset.load(.duration)
                } else {
                    duration = asset.duration
                }
                let timeRange = CMTimeRange(start: .zero, duration: duration)
                
                do {
                    let assetVideoTracks: [AVAssetTrack]
                    let assetAudioTracks: [AVAssetTrack]
                    if #available(iOS 15.0, *) {
                        assetVideoTracks = try await asset.loadTracks(withMediaType: .video)
                        assetAudioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                    } else {
                        assetVideoTracks = asset.tracks(withMediaType: .video)
                        assetAudioTracks = asset.tracks(withMediaType: .audio)
                    }
                    
                    if let vTrack = assetVideoTracks.first {
                        try videoTrack.insertTimeRange(timeRange, of: vTrack, at: insertTime)
                        if insertTime == .zero {
                            let transform: CGAffineTransform
                            let naturalSize: CGSize
                            if #available(iOS 15.0, *) {
                                transform = try await vTrack.load(.preferredTransform)
                                naturalSize = try await vTrack.load(.naturalSize)
                            } else {
                                transform = vTrack.preferredTransform
                                naturalSize = vTrack.naturalSize
                            }
                            self.videoSize = naturalSize.applying(transform)
                            self.videoSize = CGSize(width: abs(self.videoSize.width), height: abs(self.videoSize.height))
                            videoTrack.preferredTransform = transform
                        }
                    }
                    if let aTrack = assetAudioTracks.first {
                        try audioTrack.insertTimeRange(timeRange, of: aTrack, at: insertTime)
                    }
                    insertTime = CMTimeAdd(insertTime, duration)
                } catch {
                    print("Error inserting track: \(error)")
                }
            }
            
            let totalMs = Int(CMTimeGetSeconds(insertTime) * 1000)
            
            await MainActor.run {
                self.totalDurationMs = totalMs
                
                let playerItem = AVPlayerItem(asset: composition)
                let queuePlayer = AVQueuePlayer(playerItem: playerItem)
                self.playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
                
                self.playerLayer.player = queuePlayer
                self.playerLayer.videoGravity = .resizeAspect
                self.player = queuePlayer
                if self.mute {
                    queuePlayer.volume = 0
                    queuePlayer.isMuted = true
                }

                queuePlayer.play()
            }
        }
    }
    
    public func view() -> UIView {
        return videoView
    }
    
    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "play":
            player?.play()
            result(nil)
        case "pause":
            player?.pause()
            result(nil)
        case "seekTo":
            if let ms = call.arguments as? Int {
                let time = CMTime(value: CMTimeValue(ms), timescale: 1000)
                player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            result(nil)
        case "getPosition":
            if let player = player {
                let ms = Int(CMTimeGetSeconds(player.currentTime()) * 1000)
                // When looper loops, time resets, but this is a single item looping so it works exactly like Android.
                result(ms)
            } else {
                result(0)
            }
        case "getDuration":
            result(totalDurationMs)
        case "getVideoSize":
            result([Int(videoSize.width), Int(videoSize.height)])
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    deinit {
        player?.pause()
    }
}
