import 'package:flutter_test/flutter_test.dart';
import 'package:libclash_vpn_service/vpn_service.dart';

/// VpnServiceConfig 是 service.json 的 Dart 侧序列化契约：
/// 任何 toJson 漏字段都会让对应配置在设备上"静默失效"（补丁、隧道路径等），
/// 因此用全字段往返 + 关键键清单双重断言把这类 bug 锁死。
void main() {
  test('toJson/fromJson roundtrip keeps every field', () {
    final a = VpnServiceConfig();
    a.control_port = 19090;
    a.mixed_port = 17890;
    a.mode = "global";
    a.base_dir = "/base/dir";
    a.work_dir = "/work/dir";
    a.cache_dir = "/cache/dir";
    a.core_path = "/core/path";
    a.core_path_patch = "/patch/dir";
    a.core_path_patch_final = "/patch/final.yaml";
    a.core_path_script = "/script/dir";
    a.log_level = "debug";
    a.log_path = "/log/path";
    a.err_path = "/err/path";
    a.id = "profile-id-1";
    a.version = "9.9.9";
    a.name = "my profile";
    a.secret = "s3cret";
    a.install_refer = "import-url";
    a.prepare = true;
    a.profile_path = "/profile/path";
    a.config_file_path = "/service.json";
    a.tun_mode = true;
    a.tun_stack = "gvisor";
    a.wake_lock = true;
    a.auto_connect_at_boot = true;
    a.include_all_networks = true;
    a.exclude_local_networks = true;
    a.exclude_cellular_services = true;
    a.exclude_apns = true;
    a.exclude_device_communication = true;
    a.enforce_routes = true;
    a.auto_route_use_sub_ranges_by_default = true;
    a.per_app_enable = true;
    a.per_app_whitelist = true;
    a.per_app_packages = ["com.foo.app", "com.bar.app"];
    a.notification_content = "n-content";
    a.notification_disconnect = "n-disconnect";

    final b = VpnServiceConfig()..fromJson(a.toJson());

    expect(b.control_port, 19090);
    expect(b.mixed_port, 17890);
    expect(b.mode, "global");
    expect(b.base_dir, "/base/dir");
    expect(b.work_dir, "/work/dir");
    expect(b.cache_dir, "/cache/dir");
    expect(b.core_path, "/core/path");
    expect(b.core_path_patch, "/patch/dir");
    expect(b.core_path_patch_final, "/patch/final.yaml");
    expect(b.core_path_script, "/script/dir");
    expect(b.log_level, "debug");
    expect(b.log_path, "/log/path");
    expect(b.err_path, "/err/path");
    expect(b.id, "profile-id-1");
    expect(b.version, "9.9.9");
    expect(b.name, "my profile");
    expect(b.secret, "s3cret");
    expect(b.install_refer, "import-url");
    expect(b.prepare, true);
    expect(b.profile_path, "/profile/path");
    expect(b.config_file_path, "/service.json");
    expect(b.tun_mode, true);
    expect(b.tun_stack, "gvisor");
    expect(b.wake_lock, true);
    expect(b.auto_connect_at_boot, true);
    expect(b.include_all_networks, true);
    expect(b.exclude_local_networks, true);
    expect(b.exclude_cellular_services, true);
    expect(b.exclude_apns, true);
    expect(b.exclude_device_communication, true);
    expect(b.enforce_routes, true);
    expect(b.auto_route_use_sub_ranges_by_default, true);
    expect(b.per_app_enable, true);
    expect(b.per_app_whitelist, true);
    expect(b.per_app_packages, ["com.foo.app", "com.bar.app"]);
    expect(b.notification_content, "n-content");
    expect(b.notification_disconnect, "n-disconnect");
  });

  test('toJson keeps keys that historically went missing', () {
    final json = VpnServiceConfig().toJson();
    const criticalKeys = [
      'core_path_patch',
      'core_path_patch_final',
      'core_path_script',
      'config_file_path',
      'profile_path',
      'tun_stack',
      'install_refer',
      'id',
      'version',
      'name',
      'per_app_packages',
    ];
    for (final k in criticalKeys) {
      expect(json.containsKey(k), isTrue,
          reason: 'toJson 缺 $k —— 该配置会在设备上静默失效');
    }
  });
}
