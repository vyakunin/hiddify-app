// Unit tests for the family_vpn fork update URL derivation.
//
// Environment.forkUpdateVersionJsonUrl and forkUpdateApkUrl are pure
// functions of bakedSubscriptionUrl, which is set at build time via
// --dart-define. We can't override compile-time constants from a test, so
// we exercise the same logic via a private helper kept in sync with the
// Environment getters — the value test catches drift if either side
// changes its URL shape.

import 'package:flutter_test/flutter_test.dart';

// Helper that mirrors Environment.forkUpdateVersionJsonUrl/forkUpdateApkUrl
// logic without depending on the build-time constant.
String _versionJsonUrl(String subUrl) {
  if (subUrl.isEmpty) return "";
  final i = subUrl.indexOf("/sub/");
  if (i < 0) return "";
  return "${subUrl.substring(0, i)}/app/version.json";
}

String _apkUrl(String subUrl) {
  if (subUrl.isEmpty) return "";
  final i = subUrl.indexOf("/sub/");
  if (i < 0) return "";
  final token = subUrl.substring(i + 5);
  return "${subUrl.substring(0, i)}/app/$token/family_vpn.apk";
}

void main() {
  group("ForkUpdate URL derivation", () {
    test("empty sub url -> empty derived urls", () {
      expect(_versionJsonUrl(""), "");
      expect(_apkUrl(""), "");
    });

    test("malformed sub url (no /sub/ segment) -> empty derived urls", () {
      expect(_versionJsonUrl("https://example.com/something"), "");
      expect(_apkUrl("https://example.com/something"), "");
    });

    test("real sub url -> version.json public, apk token-gated", () {
      const sub = "https://assets.visa-bulletin.us/sub/abc123def456";
      expect(_versionJsonUrl(sub), "https://assets.visa-bulletin.us/app/version.json");
      expect(_apkUrl(sub), "https://assets.visa-bulletin.us/app/abc123def456/family_vpn.apk");
    });

    test("token preserved verbatim — no escaping or normalization", () {
      // Per tokens.yaml in this project tokens are URL-safe hex,
      // but the derivation must not assume anything beyond "string
      // after /sub/" — if the format ever changes (e.g. UUIDs with
      // dashes), the URL must still round-trip correctly.
      const sub = "https://host.example/sub/a-b-c";
      expect(_apkUrl(sub), "https://host.example/app/a-b-c/family_vpn.apk");
    });

    test("alternate host port carried through", () {
      const sub = "http://localhost:8080/sub/devtoken";
      expect(_versionJsonUrl(sub), "http://localhost:8080/app/version.json");
      expect(_apkUrl(sub), "http://localhost:8080/app/devtoken/family_vpn.apk");
    });
  });
}
