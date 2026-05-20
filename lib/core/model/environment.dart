import 'package:dartx/dartx.dart';

enum Environment {
  prod,
  dev;

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

  // family_vpn fork: in-app APK update channel served from the same host
  // as the baked subscription. When enabled, the app polls
  //   <sub-host>/app/version.json
  // on each launch (after baked-sub refresh) and downloads
  //   <sub-host>/app/<token>/family_vpn.apk
  // through the VPN tunnel when a newer versionCode is available. The
  // download is staged in app-private cache and surfaced to the UI on
  // the next Connect tap as "Update & connect" (hard nudge — see
  // PROJECT NEXT.md, "APK push design").
  //
  // Off by default so the slim baseline APK keeps shipping to relatives
  // without behavior change while the install-intent plumbing matures.
  // Enable in a future build via --dart-define=enable_fork_update=true.
  static const enableForkUpdate = bool.fromEnvironment("enable_fork_update");

  // family_vpn fork (Play distribution branch): when true, the app does NOT
  // ship with a baked sub URL. On first launch the user signs in with
  // Google; we POST the resulting ID token to <oauth_exchange_url> and the
  // server returns the sub URL for the matching gmail. The fork-update
  // channel is force-disabled in this mode because Play handles updates.
  static const enableOauth = bool.fromEnvironment("enable_oauth");

  // Google OAuth client ID (Android type) used by GoogleSignIn. Injected
  // at build time so the fork-slim baseline can ship without it.
  static const playOauthClientId = String.fromEnvironment("play_oauth_client_id");

  // Endpoint that exchanges a Google ID token for a per-user sub URL.
  // Defaults to assets.vyakunin.org since the OAuth flow only runs in the
  // Play branch and that's where the endpoint is wired.
  static const oauthExchangeUrl = String.fromEnvironment(
    "oauth_exchange_url",
    defaultValue: "https://assets.vyakunin.org/oauth/exchange",
  );

  static bool get hasPlayOauth =>
      enableOauth && playOauthClientId.isNotEmpty && oauthExchangeUrl.isNotEmpty;

  // Derived from bakedSubscriptionUrl. /sub/<token> → /app/version.json
  // and /app/<token>/family_vpn.apk live at the same host. Returns empty
  // strings when there's no baked sub (then the update channel is moot).
  static String get forkUpdateVersionJsonUrl {
    if (bakedSubscriptionUrl.isEmpty) return "";
    final i = bakedSubscriptionUrl.indexOf("/sub/");
    if (i < 0) return "";
    return "${bakedSubscriptionUrl.substring(0, i)}/app/version.json";
  }

  static String get forkUpdateApkUrl {
    if (bakedSubscriptionUrl.isEmpty) return "";
    final i = bakedSubscriptionUrl.indexOf("/sub/");
    if (i < 0) return "";
    final token = bakedSubscriptionUrl.substring(i + 5); // after "/sub/"
    return "${bakedSubscriptionUrl.substring(0, i)}/app/$token/family_vpn.apk";
  }
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
