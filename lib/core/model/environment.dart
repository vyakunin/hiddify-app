import 'package:dartx/dartx.dart';

enum Environment {
  prod,
  dev;

  static const sentryDSN = String.fromEnvironment("sentry_dsn");
  // This environment variable is set in the 'windows-release-zip' command
  static const isPortable = bool.fromEnvironment("portable");

  // family_vpn fork: subscription URL baked at build time via
  // --dart-define=baked_sub_url=https://...
  // When non-empty, the app silently auto-imports this URL on first launch
  // and skips the intro/onboarding screen — see RoutingConfigNotifier.
  static const bakedSubscriptionUrl = String.fromEnvironment("baked_sub_url");
  static bool get hasBakedSubscription => bakedSubscriptionUrl.isNotEmpty;
}

enum Release {
  general("general"),
  // This environment variable is set in the 'android-release-aab' command
  googlePlay("google-play");

  const Release(this.key);

  final String key;

  bool get allowCustomUpdateChecker => this == general;

  static Release read() =>
      Release.values.firstOrNullWhere((e) => e.key == const String.fromEnvironment("release")) ?? Release.general;
}
