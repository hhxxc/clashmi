import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let CHANNEL = "com.nebula.clashmi/native_helper"
  private let appGroupId = "group.com.nebula.clashmi"

  // TrollStore FakeVPN: the core runs as an independent root process
  // (TSRootBinaries + com.apple.private.persona-mgmt spawnRoot), creating a
  // user-space utun tunnel and system routes. No NetworkExtension involved —
  // ldid fake-signed NE providers are rejected by nesessionmanager.
  private let pidFileName = "roothelper.pid"
  private let ifaceFileName = "roothelper.iface"
  private var cachedContainerPath: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as? FlutterViewController
    if let messenger = controller?.binaryMessenger {
      setupNativeHelperChannel(messenger: messenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ClashMiNativeHelper") {
      setupNativeHelperChannel(messenger: registrar.messenger())
    }
  }

  // MARK: - Paths

  private func containerPath() -> String {
    if let cached = cachedContainerPath {
      return cached
    }
    var path: String
    if let containerUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
      path = containerUrl.path
    } else {
      // Fallback for environments without App Group resolution (iOS Simulator
      // ad-hoc signing). Real devices (ldid fake-sign with app-groups) resolve.
      let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first!
      let fallback = appSupport.appendingPathComponent(appGroupId)
      try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
      path = fallback.path
    }
    cachedContainerPath = path
    return path
  }

  private var pidFilePath: String {
    (containerPath() as NSString).appendingPathComponent(pidFileName)
  }

  private var ifaceFilePath: String {
    (containerPath() as NSString).appendingPathComponent(ifaceFileName)
  }

  private func rootHelperPath() -> String? {
    Bundle.main.path(forResource: "roothelper", ofType: nil)
  }

  /// Reads the VpnServiceConfig JSON written by Dart and returns the
  /// roothelper argv tail (config paths + dirs). Pid/iface files are appended
  /// by the caller.
  private func rootHelperArgs(configFilePath: String) -> [String]? {
    guard
      let data = FileManager.default.contents(atPath: configFilePath),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      NSLog("[native_helper] cannot parse service config: \(configFilePath)")
      return nil
    }
    func str(_ key: String) -> String { obj[key] as? String ?? "" }
    return [
      str("core_path"),
      str("core_path_patch"),
      str("core_path_patch_final"),
      str("base_dir"),
      str("log_path"),
      str("err_path"),
    ]
  }

  /// Returns the pid recorded in the pidfile, or 0 if absent/invalid.
  private func recordedPid() -> Int32 {
    guard
      let text = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
      let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
      pid > 0
    else {
      return 0
    }
    return pid
  }

  private func isHelperRunning() -> Bool {
    let pid = recordedPid()
    return pid > 0 && kill(pid, 0) == 0
  }

  // MARK: - Native helper channel

  private func setupNativeHelperChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: CHANNEL, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else {
        result(FlutterError(code: "DEALLOCATED", message: "AppDelegate deallocated", details: nil))
        return
      }

      switch call.method {
      case "checkVpnPermission":
        // No system VPN permission needed for the root FakeVPN.
        result(true)

      case "requestVpnPermission":
        result(true)

      case "startVpnService":
        guard let helperPath = self.rootHelperPath() else {
          result(FlutterError(code: "NO_HELPER", message: "roothelper binary missing from bundle", details: nil))
          return
        }
        let args = call.arguments as? [String: Any]
        let configFilePath = args?["configFilePath"] as? String ?? ""
        guard configFilePath.isEmpty == false else {
          result(FlutterError(code: "NO_CONFIG", message: "configFilePath empty", details: nil))
          return
        }
        guard var helperArgs = self.rootHelperArgs(configFilePath: configFilePath) else {
          result(FlutterError(code: "BAD_CONFIG", message: "service config unreadable", details: nil))
          return
        }
        // Idempotent restart: kill any previous instance first.
        self.stopHelperSync()

        helperArgs.append(self.pidFilePath)
        helperArgs.append(self.ifaceFilePath)

        // Wait until roothelper writes its pidfile (it does so before
        // LibclashStart; Dart probes the external-controller for real readiness).
        let spawned = TSSpawnRootAndWaitForPidFile(
          helperPath, helperArgs, self.pidFilePath, 15.0
        )
        result(spawned)

      case "stopVpnService":
        self.stopHelperSync()
        result(true)

      case "getVpnStatus":
        result(self.isHelperRunning() ? "connected" : "disconnected")

      case "getAppGroupDirectory":
        let args = call.arguments as? [String: Any]
        let groupId = args?["groupId"] as? String ?? self.appGroupId
        if let containerUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) {
          result(containerUrl.path)
        } else {
          let fallback = self.containerPath()
          NSLog("[native_helper] App Group unavailable, falling back to \(fallback)")
          result(fallback)
        }

      case "hideDockIcon", "getNativeLibraryPath", "getNativeLibraryDir":
        // macOS / Android only; not applicable on iOS.
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Spawns `roothelper stop <pidFile>` to ask the running instance to exit,
  /// and removes stale state files.
  private func stopHelperSync() {
    guard isHelperRunning(), let helperPath = rootHelperPath() else {
      cleanupHelperState()
      return
    }
    _ = TSSpawnRoot(helperPath, ["stop", pidFilePath])
    // Give the helper a moment to clean up routes and exit.
    let pid = recordedPid()
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if pid == 0 || kill(pid, 0) != 0 {
        break
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    cleanupHelperState()
  }

  private func cleanupHelperState() {
    try? FileManager.default.removeItem(atPath: pidFilePath)
    try? FileManager.default.removeItem(atPath: ifaceFilePath)
  }
}
