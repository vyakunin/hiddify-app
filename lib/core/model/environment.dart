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

  // family_vpn fork: minimal UI mode for grandma-friendly layout.
  // Hides bottom nav, settings/profiles/logs tabs — single Connect button
  // with a friendly stats panel. Defaults true for our distribution.
  static const minimalUi = bool.fromEnvironment("minimal_ui", defaultValue: true);

  // Display name override (replaces Constants.appName everywhere it's
  // surfaced to the user). Defaults to "Заметки" — the camouflage name.
  static const appDisplayName = String.fromEnvironment(
    "app_display_name",
    defaultValue: "Заметки",
  );

  // Force locale. When non-empty, takes precedence over device locale.
  // E.g. --dart-define=force_locale=ru ensures Russian UI even on a
  // device whose system locale is something else.
  static const forceLocale = String.fromEnvironment("force_locale", defaultValue: "ru");
  static bool get hasForcedLocale => forceLocale.isNotEmpty;
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
