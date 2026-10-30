import 'package:package_info_plus/package_info_plus.dart';

/// Fallback app version when PackageInfo is not available (e.g. in test runners).
const String kAppVersionFallback = '1.50.3+137';

/// Retrieves the formatted application version string (e.g. `v1.50.3 (build 137)`).
Future<String> getAppVersionString() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return 'v${info.version}${info.buildNumber.isNotEmpty ? ' (build ${info.buildNumber})' : ''}';
  } catch (_) {
    return 'v$kAppVersionFallback';
  }
}
