// Stub for upstream's closed-source private module (gitignored in KaringX/clashmi).
// Vendored from aimy1/Wmimo's lib/app/private (empty stubs): analytics query
// signing and board-provider endpoints are no-ops, which only disables
// upstream's notice/telemetry board — VPN and core features are unaffected.
import 'package:tuple/tuple.dart';

class AppUrlUtilsPrivate {
  static String signQueryParams(String version, String bodyLen, Map<String, dynamic> params) {
    return "";
  }
  static String signQueryParams2(String version, Map<String, dynamic> params, {String bodyLen = "0"}) {
    return "";
  }
}

class BoardProviderPrivate {
  static Tuple3<String, String, dynamic> getNoticePushUrlAndBody({
    required String app,
    required String version,
    required String did,
    required String pid,
  }) => const Tuple3("", "", "");

  static Tuple3<String, String, dynamic> getBycodeUrlAndBody({
    required String app,
    required String version,
    required String did,
    required String code,
  }) => const Tuple3("", "", "");

  static Tuple3<String, String, dynamic> getNotifyIntegrationUrlAndBody({
    required String app,
    required String version,
    required String did,
    required String url,
    required String type,
  }) => const Tuple3("", "", "");
}

class ProfileProxyProviderPrivate {
  static Tuple3<String, String, dynamic> getProviderProxyUrlAndBody({
    required String app,
    required String version,
    required String did,
    required String boardProviderId,
    required String url,
    required String userAgent,
    required Map<String, String> xhwidHeaders,
  }) => const Tuple3("", "", "");
}
