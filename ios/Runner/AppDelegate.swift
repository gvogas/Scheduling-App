import Flutter
import GoogleMaps
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    FlutterMessengers.capture(messenger)
    registerNativeConfigChannel(messenger: messenger)
    CarPlayBridge.shared.register(messenger: messenger)
  }

  private func registerNativeConfigChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "net.vogas.scheduling/native_config",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "provideGoogleMapsApiKey" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let key = call.arguments as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        NSLog("IOS_MAPS_API_KEY missing - live map will be blank")
        result(nil)
        return
      }
      GMSServices.provideAPIKey(key)
      result(nil)
    }
  }
}
