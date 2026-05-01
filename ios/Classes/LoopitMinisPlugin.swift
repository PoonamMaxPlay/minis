import Flutter
import UIKit

public class LoopitMinisPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let factory = MinisPreviewPlayerFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: "minis_preview_player")
  }
}
