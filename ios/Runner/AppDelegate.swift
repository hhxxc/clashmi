import Flutter
import UIKit
import NetworkExtension

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let CHANNEL = "com.nebula.clashmi/native_helper"
  private let appGroupId = "group.com.nebula.clashmi"
  private let tunnelBundleId = "com.nebula.clashmi.clashmiService"
  private var vpnManager: NETunnelProviderManager?

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

  private func setupNativeHelperChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: CHANNEL, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else {
        result(FlutterError(code: "DEALLOCATED", message: "AppDelegate deallocated", details: nil))
        return
      }

      switch call.method {
      case "checkVpnPermission":
        self.loadVpnManager { manager in
          result(manager != nil && manager?.isEnabled == true)
        }

      case "requestVpnPermission":
        self.loadOrCreateVpnManager { manager, error in
          if let error = error {
            result(FlutterError(code: "VPN_PERMISSION_ERROR", message: error.localizedDescription, details: nil))
            return
          }
          result(manager != nil)
        }

      case "startVpnService":
        let args = call.arguments as? [String: Any]
        // ExtensionProvider reads providerConfiguration["configFilePath"] and
        // decodes it as VpnServiceConfig (service.json in the App Group container).
        let configFilePath = args?["configFilePath"] as? String ?? ""

        self.loadOrCreateVpnManager { manager, error in
          guard let manager = manager else {
            result(FlutterError(code: "VPN_MANAGER_UNAVAILABLE", message: error?.localizedDescription ?? "VPN manager unavailable", details: nil))
            return
          }

          manager.isEnabled = true
          let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
          proto.providerBundleIdentifier = self.tunnelBundleId
          proto.serverAddress = "Clash Mi"
          proto.providerConfiguration = ["configFilePath": configFilePath]
          manager.protocolConfiguration = proto
          manager.localizedDescription = "Clash Mi"

          manager.saveToPreferences { saveErr in
            if let saveErr = saveErr {
              result(FlutterError(code: "SAVE_FAILED", message: saveErr.localizedDescription, details: nil))
              return
            }
            manager.loadFromPreferences { loadErr in
              if let loadErr = loadErr {
                result(FlutterError(code: "LOAD_FAILED", message: loadErr.localizedDescription, details: nil))
                return
              }
              do {
                try manager.connection.startVPNTunnel()
                result(true)
              } catch {
                result(FlutterError(code: "START_FAILED", message: error.localizedDescription, details: nil))
              }
            }
          }
        }

      case "stopVpnService":
        self.loadVpnManager { manager in
          manager?.connection.stopVPNTunnel()
          result(true)
        }

      case "getVpnStatus":
        self.loadVpnManager { manager in
          guard let status = manager?.connection.status else {
            result("disconnected")
            return
          }
          switch status {
          case .connected: result("connected")
          case .connecting: result("connecting")
          case .disconnecting: result("disconnecting")
          default: result("disconnected")
          }
        }

      case "getAppGroupDirectory":
        let args = call.arguments as? [String: Any]
        let groupId = args?["groupId"] as? String ?? self.appGroupId
        if let containerUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) {
          result(containerUrl.path)
        } else {
          result(nil)
        }

      case "hideDockIcon", "getNativeLibraryPath", "getNativeLibraryDir":
        // macOS / Android only; not applicable on iOS.
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func loadVpnManager(completion: @escaping (NETunnelProviderManager?) -> Void) {
    if let existing = self.vpnManager {
      completion(existing)
      return
    }
    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
      let manager = managers?.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self?.tunnelBundleId }
      self?.vpnManager = manager
      completion(manager)
    }
  }

  private func loadOrCreateVpnManager(completion: @escaping (NETunnelProviderManager?, Error?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
      if let error = error {
        completion(nil, error)
        return
      }
      guard let self = self else {
        completion(nil, nil)
        return
      }
      let manager = managers?.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.tunnelBundleId } ?? NETunnelProviderManager()
      self.vpnManager = manager
      completion(manager, nil)
    }
  }
}
