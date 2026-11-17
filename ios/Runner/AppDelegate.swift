import UIKit
import Flutter
import Photos

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  private let CHANNEL = "com.universal.filetransfer/native"
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    let methodChannel = FlutterMethodChannel(name: CHANNEL, binaryMessenger: controller.binaryMessenger)

    methodChannel.setMethodCallHandler({
      [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      switch call.method {

      // Wake Lock & Background Keep-Alive for iOS
      case "acquireWakeLock":
        DispatchQueue.main.async {
          // 1. Prevent screen auto-lock / dimming
          UIApplication.shared.isIdleTimerDisabled = true

          // 2. Begin background task so TCP socket does not terminate if user briefly leaves app
          if self?.backgroundTaskId == .invalid {
            self?.backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "UniversalTransferActive") {
              self?.endBackgroundTask()
            }
          }
          result(true)
        }

      case "releaseWakeLock":
        DispatchQueue.main.async {
          // Restore normal idle timer
          UIApplication.shared.isIdleTimerDisabled = false
          self?.endBackgroundTask()
          result(true)
        }

      // Photos Framework Auto-Routing
      case "saveImageToGallery":
        guard let args = call.arguments as? [String: Any],
              let filePath = args["path"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Path is required", details: nil))
          return
        }
        self?.saveToCameraRoll(path: filePath, isVideo: false, result: result)

      case "saveVideoToGallery":
        guard let args = call.arguments as? [String: Any],
              let filePath = args["path"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Path is required", details: nil))
          return
        }
        self?.saveToCameraRoll(path: filePath, isVideo: true, result: result)

      // Documents Directory for raw files / binaries (visible in iOS Files app)
      case "getUniversalShareDirectory":
        if let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
          let shareDir = docsDir.appendingPathComponent("UniversalShare")
          if !FileManager.default.fileExists(atPath: shareDir.path) {
            try? FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true, attributes: nil)
          }
          result(shareDir.path)
        } else {
          result(FlutterError(code: "DIR_ERROR", message: "Could not access documents directory", details: nil))
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    })

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func endBackgroundTask() {
    if backgroundTaskId != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTaskId)
      backgroundTaskId = .invalid
    }
  }

  private func saveToCameraRoll(path: String, isVideo: Bool, result: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization { status in
      guard status == .authorized || status == .limited else {
        result(FlutterError(code: "PERMISSION_DENIED", message: "Photo library access denied", details: nil))
        return
      }

      PHPhotoLibrary.shared().performChanges({
        let fileUrl = URL(fileURLWithPath: path)
        if isVideo {
          PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileUrl)
        } else {
          PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileUrl)
        }
      }) { success, error in
        DispatchQueue.main.async {
          if success {
            result(true)
          } else {
            result(FlutterError(code: "SAVE_FAILED", message: error?.localizedDescription ?? "Failed to save asset", details: nil))
          }
        }
      }
    }
  }
}
