import Flutter
import UIKit

public class LoopitMinisPlugin: NSObject, FlutterPlugin {
  private static var instances: [LoopitMinisPlugin] = []

  private var paths: Paths?
  private var wakelock: Wakelock?
  private var permissions: Permissions?
  private var deviceInfo: DeviceInfo?
  private var filePicker: FilePickerNative?
  private var mediaPicker: AnyObject?
  private var share: Share?
  private var playerEngine: VideoPlayerEngine?
  private var audioPlugin: MinisAudioPlugin?
  private var cameraChannel: MinisCameraChannel?
  private var minisCamPerms: MinisCameraPermissions?
  private var minisCamPermsChannel: FlutterMethodChannel?
  private var videoEditEngine: VideoEditEngine?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    let factory = MinisPreviewPlayerFactory(messenger: messenger)
    registrar.register(factory, withId: "minis_preview_player")

    let imgEditFactory = ImageEditPlatformViewFactory()
    registrar.register(
      imgEditFactory,
      withId: ImageEditPluginRouter.platformViewType
    )
    ImageEditPluginRouter.shared.attach(messenger: messenger)
    ImageEditPluginRouter.shared.observeMemoryWarnings()

    let emojiFactory = EmojiPickerViewFactory(messenger: messenger)
    registrar.register(emojiFactory, withId: "loopit/minis/emoji_picker")

    let instance = LoopitMinisPlugin()
    instance.paths = Paths(messenger: messenger)
    instance.wakelock = Wakelock(messenger: messenger)
    instance.permissions = Permissions(messenger: messenger)
    instance.deviceInfo = DeviceInfo(messenger: messenger)
    let fp = FilePickerNative()
    instance.filePicker = fp
    if #available(iOS 14, *) {
      instance.mediaPicker = MediaPicker(messenger: messenger, filePicker: fp)
    }
    instance.share = Share(messenger: messenger)
    let engine = VideoPlayerEngine(messenger: messenger)
    instance.playerEngine = engine
    let viewFactory = VideoPlayerViewFactory(engine: engine)
    registrar.register(viewFactory, withId: VideoPlayerViewFactory.viewType)
    instance.audioPlugin = MinisAudioPlugin(messenger: messenger)
    let waveformFactory = MinisWaveformViewFactory(messenger: messenger)
    registrar.register(waveformFactory, withId: "loopit/minis/audio/waveform")

    // Minis native camera.
    let camChan = MinisCameraChannel()
    camChan.register(messenger: messenger)
    instance.cameraChannel = camChan
    let camFactory = MinisCameraPlatformViewFactory(engine: camChan.engine, secondary: false)
    registrar.register(camFactory, withId: "loopit/minis/camera/preview")
    let camFactory2 = MinisCameraPlatformViewFactory(engine: camChan.engine, secondary: true)
    registrar.register(camFactory2, withId: "loopit/minis/camera/preview_secondary")
    // Legacy platform-view id for back-compat with existing Dart engine.
    let camFactoryLegacy = MinisCameraPlatformViewFactory(engine: camChan.engine, secondary: false)
    registrar.register(camFactoryLegacy, withId: "minis_native_camera")

    let perms = MinisCameraPermissions()
    instance.minisCamPerms = perms
    let permsChan = FlutterMethodChannel(name: "loopit/minis/permissions", binaryMessenger: messenger)
    permsChan.setMethodCallHandler { call, result in perms.handle(call, result: result) }
    instance.minisCamPermsChannel = permsChan

    // Video editor (improvement3.md): MethodChannel + EventChannels + PlatformView.
    instance.videoEditEngine = VideoEditEngine(messenger: messenger)
    let videditFactory = VideoEditPlatformViewFactory(messenger: messenger)
    registrar.register(videditFactory, withId: "loopit/minis/videdit/preview")

    // Telemetry hook (improvement F3). Off by default; host opts in.
    MinisTelemetry.shared.attach(messenger: messenger)

    instances.append(instance)
  }
}
