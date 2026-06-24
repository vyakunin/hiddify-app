// family_vpn fork (Play distribution branch): first-launch Sign-in-with-Google
// screen. Shown when there is no active profile AND no baked sub URL. After a
// successful sign-in the screen POSTs the Google ID token to the sub_server
// /oauth/exchange endpoint and feeds the returned sub URL into the existing
// AddProfile flow via ProfileRepository.upsertRemote.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/log/data/log_bundle.dart';
import 'package:hiddify/features/log/data/log_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class OauthSigninPage extends ConsumerStatefulWidget {
  const OauthSigninPage({super.key});

  @override
  ConsumerState<OauthSigninPage> createState() => _OauthSigninPageState();
}

class _OauthSigninPageState extends ConsumerState<OauthSigninPage> {
  bool _busy = false;
  String? _error;

  late final GoogleSignIn _signIn = GoogleSignIn(
    serverClientId: Environment.playOauthClientId,
    scopes: const ["email"],
  );

  @override
  void initState() {
    super.initState();
    // Try a silent (no-UI) sign-in first. After a reinstall the device is
    // still signed into Google at the OS level, so Play Services can usually
    // resolve a previously-granted account without showing the chooser. If it
    // succeeds we complete the whole flow hands-free; if it returns null the
    // interactive button is revealed and the user taps once.
    WidgetsBinding.instance.addPostFrameCallback((_) => _attemptSilent());
  }

  Future<void> _attemptSilent() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      Logger.bootstrap.info("oauth: attempting signInSilently()");
      final account = await _signIn.signInSilently();
      if (account == null) {
        Logger.bootstrap.info("oauth: silent sign-in returned null — showing interactive button");
        if (mounted) setState(() => _busy = false);
        return;
      }
      Logger.bootstrap.info("oauth: silent sign-in succeeded (email=${account.email})");
      await _completeWithAccount(account);
    } catch (e, s) {
      // Silent failure is expected (no cached grant, network blip) — fall back
      // to the interactive button silently, do NOT surface an error.
      Logger.bootstrap.info("oauth: silent sign-in failed ($e) — showing interactive button", e, s);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onSignIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    Logger.bootstrap.info(
      "oauth: starting sign-in (serverClientId=${Environment.playOauthClientId.substring(0, 24)}…, "
      "exchange=${Environment.oauthExchangeUrl})",
    );
    try {
      Logger.bootstrap.info("oauth: calling GoogleSignIn.signIn()");
      final account = await _signIn.signIn();
      if (account == null) {
        Logger.bootstrap.warning("oauth: GoogleSignIn returned null (cancelled by user)");
        setState(() {
          _busy = false;
          _error = "sign-in cancelled";
        });
        return;
      }
      await _completeWithAccount(account);
    } catch (e, s) {
      Logger.bootstrap.warning("oauth sign-in failed: $e", e, s);
      if (mounted) {
        setState(() {
          _busy = false;
          _error = "$e";
        });
      }
    }
  }

  // Shared tail of both the silent and interactive paths: exchange the Google
  // ID token at the sub_server and import the returned sub URL. Throws on any
  // failure; callers translate that into _error.
  Future<void> _completeWithAccount(GoogleSignInAccount account) async {
    try {
      Logger.bootstrap.info("oauth: got account (email=${account.email})");
      final auth = await account.authentication;
      final idToken = auth.idToken;
      Logger.bootstrap.info(
        "oauth: got authentication (idToken present=${idToken != null && idToken.isNotEmpty}, "
        "accessToken present=${auth.accessToken != null && auth.accessToken!.isNotEmpty})",
      );
      if (idToken == null || idToken.isEmpty) {
        throw StateError("google_sign_in returned no ID token (check OAuth client config)");
      }

      Logger.bootstrap.info("oauth: POSTing to ${Environment.oauthExchangeUrl}");
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        responseType: ResponseType.json,
      ));
      final resp = await dio.post(
        Environment.oauthExchangeUrl,
        data: jsonEncode({"id_token": idToken}),
        options: Options(
          headers: {"Content-Type": "application/json"},
          validateStatus: (_) => true,
        ),
      );
      Logger.bootstrap.info("oauth: exchange responded HTTP ${resp.statusCode} body=${resp.data}");
      if (resp.statusCode != 200) {
        throw StateError(_friendlyError(resp.statusCode, resp.data));
      }
      final body = resp.data as Map<String, dynamic>;
      final subUrl = body["sub_url"] as String?;
      if (subUrl == null || subUrl.isEmpty) {
        throw StateError("server returned empty sub URL");
      }
      Logger.bootstrap.info("oauth: importing profile from sub URL");

      final repo = await ref.read(profileRepositoryProvider.future);
      final result = await repo.upsertRemote(subUrl).run();
      result.match(
        (f) => throw StateError("could not import profile: $f"),
        (_) => Logger.bootstrap.info("oauth: profile imported"),
      );
      // Routing watches activeProfileProvider; once a profile is added the
      // router redirects to /home automatically. Nothing else to do here.
    } catch (e, s) {
      Logger.bootstrap.warning("oauth sign-in failed: $e", e, s);
      if (mounted) {
        setState(() {
          _busy = false;
          _error = "$e";
        });
      }
    }
  }

  Future<void> _shareLogs() async {
    try {
      final pathResolver = ref.read(logPathResolverProvider);
      final file = await LogBundle(pathResolver).buildCombinedFile();
      await UriUtils.tryShareOrLaunchFile(
        Uri.parse(file.path),
        fileOrDir: file.parent.uri,
      );
    } catch (e, s) {
      Logger.bootstrap.warning("oauth: share-logs failed: $e", e, s);
    }
  }

  String _friendlyError(int? code, Object? data) {
    if (code == 403) {
      return "Этот gmail не в списке семьи. Попроси хозяина добавить его.";
    }
    if (code == 400) {
      return "Google login failed validation. Try again.";
    }
    return "Server error: HTTP $code. $data";
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(),
              Text(
                Environment.appDisplayName,
                style: theme.textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                "Войди через Google, чтобы привязать приложение к своему аккаунту.",
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              if (_error != null) ...[
                Text(
                  _error!,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
              ],
              FilledButton.icon(
                onPressed: _busy ? null : _onSignIn,
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.login),
                label: Text(_busy ? "..." : "Sign in with Google"),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
              const SizedBox(height: 16),
              // family_vpn fork: log-share entrypoint mirroring the home-screen
              // button. If sign-in fails repeatedly the user is stuck on this
              // page with no other way to get diagnostic logs out.
              TextButton.icon(
                onPressed: _shareLogs,
                icon: const Text("📋", style: TextStyle(fontSize: 16)),
                label: const Text("Поделиться логами"),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  textStyle: theme.textTheme.bodySmall,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const Spacer(),
              Text(
                "Только для членов семьи",
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
