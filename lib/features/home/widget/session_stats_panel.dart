// family_vpn fork: friendly Russian-language session stats below the
// Connect button on the home screen. Visible when the VPN is connected.
// Replaces the upstream ActiveProxyFooter with a grandma-friendly layout.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/log/data/log_bundle.dart';
import 'package:hiddify/features/log/data/log_data_providers.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/stats/notifier/stats_notifier.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class SessionStatsPanel extends HookConsumerWidget {
  const SessionStatsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final connection = ref.watch(connectionNotifierProvider).valueOrNull;
    final statsAsync = ref.watch(statsNotifierProvider);
    final activeProxy = ref.watch(activeProxyNotifierProvider).valueOrNull;

    // family_vpn fork: session-start timestamp is owned by Kotlin
    // (BoxService writes Settings.connectedSinceMs on Status.Started,
    // clears on Status.Stopped). We fetch it via MethodChannel on every
    // transition into Connected — that way Activity rebuilds and Dart
    // stream re-subscriptions can never reset the visible timer (they
    // briefly emit Disconnected→Connected while the bg tunnel stays up,
    // and the value Kotlin holds doesn't change across that glitch).
    final connectedSinceMs = useState<int>(0);
    final ticker = useState(0);

    useEffect(() {
      final timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => ticker.value = ticker.value + 1,
      );
      return timer.cancel;
    }, const []);

    final isConnected = connection is Connected;
    useEffect(() {
      if (!isConnected) {
        connectedSinceMs.value = 0;
        return null;
      }
      // Fetch immediately on entering Connected; the value is stable for the
      // rest of the session so a single fetch per Connected transition is
      // enough. If the very first fetch races with BoxService's write, the
      // tick-driven rebuild won't re-fetch — so we schedule one retry after
      // 300ms to cover that narrow window.
      var disposed = false;
      Future<void> fetch() async {
        final v = await ref.read(hiddifyCoreServiceProvider).core.getConnectedSinceMs();
        if (!disposed) connectedSinceMs.value = v;
      }
      fetch();
      Future.delayed(const Duration(milliseconds: 300), () {
        if (disposed) return;
        if (connectedSinceMs.value == 0) fetch();
      });
      return () => disposed = true;
    }, [isConnected]);

    Widget body;
    if (connection is Connected) {
      final elapsed = connectedSinceMs.value > 0
          ? DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(connectedSinceMs.value))
          : Duration.zero;

      final stats = statsAsync.valueOrNull;
      final downTotal = stats?.downlinkTotal.toInt() ?? 0;
      final upTotal = stats?.uplinkTotal.toInt() ?? 0;
      final downSpeed = stats?.downlink.toInt() ?? 0;
      final upSpeed = stats?.uplink.toInt() ?? 0;
      final latencyMs = activeProxy?.urlTestDelay ?? 0;
      final exit = _exitLabel(activeProxy?.host ?? "", activeProxy?.tag ?? "");

      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (exit != null)
            _statRow(theme, "🌍  Выход через", exit),
          if (exit != null) const SizedBox(height: 8),
          _statRow(theme, "⏱  Время сессии", _formatDuration(elapsed)),
          const SizedBox(height: 8),
          _statRow(
            theme,
            "⬇ Скачано / ⬆ Загружено",
            "${_formatBytes(downTotal)}  /  ${_formatBytes(upTotal)}",
          ),
          const SizedBox(height: 8),
          _statRow(
            theme,
            "🚀  Скорость",
            "↓ ${_formatRate(downSpeed)}   ↑ ${_formatRate(upSpeed)}",
          ),
          const SizedBox(height: 8),
          if (latencyMs > 0)
            _statRow(theme, "📡  Задержка", "$latencyMs мс"),
        ],
      );
    } else if (connection is Disconnected && connection.connectionFailure != null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          "⚠️  Не удалось подключиться. Нажмите кнопку, чтобы попробовать снова.",
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    } else if (connection is Connecting) {
      body = Text(
        "Подключение…",
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.primary,
        ),
      );
    } else {
      body = Text(
        "Нажмите кнопку, чтобы подключиться",
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      );
    }

    final pathResolver = ref.watch(logPathResolverProvider);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            body,
            const SizedBox(height: 12),
            // family_vpn fork: persistent log-share entrypoint. The minimal UI
            // strips the AppBar that normally hosts navigation to the Logs
            // page, so a stuck relative has no other way to get diagnostic
            // logs out. One button — builds a single file containing both
            // app and core logs and hands it to the system share sheet
            // (WhatsApp, Telegram, …).
            TextButton.icon(
              onPressed: () async {
                final file = await LogBundle(pathResolver).buildCombinedFile();
                await UriUtils.tryShareOrLaunchFile(
                  Uri.parse(file.path),
                  fileOrDir: file.parent.uri,
                );
              },
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
          ],
        ),
      ),
    );
  }

  Widget _statRow(ThemeData theme, String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }

  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? "$h:$m:$s" : "$m:$s";
  }

  static String _formatBytes(int b) {
    if (b < 1024) return "$b Б";
    if (b < 1024 * 1024) return "${(b / 1024).toStringAsFixed(1)} КБ";
    if (b < 1024 * 1024 * 1024) return "${(b / 1024 / 1024).toStringAsFixed(1)} МБ";
    return "${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} ГБ";
  }

  static String _formatRate(int bytesPerSec) {
    return "${_formatBytes(bytesPerSec)}/с";
  }

  // family_vpn fork: map the active outbound's host (or, as a fallback, its
  // tag — which sub_server formats as "family_vpn — <user> — <host> — <cover>")
  // to a human-friendly country label. Returns null when we can't tell — e.g.
  // a group's aggregate row or a host we haven't deployed.
  //
  // Known data-plane hosts (kept in sync with /opt/stack/family_vpn/data_plane.yaml
  // on every host):
  //   74.208.22.246              → US (IONOS VPS, Lenexa KS)
  //   node1.vyakunin.org         → DE (homeserver, Berlin) — primary DNS name
  //   node1.visa-bulletin.us     → DE (homeserver) — backcompat DNS name
  static String? _exitLabel(String host, String tag) {
    final probe = host.isNotEmpty ? host : tag;
    if (probe.contains("74.208.22.246")) return "🇺🇸  США (Lenexa)";
    if (probe.contains("node1.vyakunin.org") ||
        probe.contains("node1.visa-bulletin.us")) {
      return "🇩🇪  Германия (Berlin)";
    }
    return null;
  }
}
