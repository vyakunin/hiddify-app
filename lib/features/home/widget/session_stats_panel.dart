// family_vpn fork: friendly Russian-language session stats below the
// Connect button on the home screen. Visible when the VPN is connected.
// Replaces the upstream ActiveProxyFooter with a grandma-friendly layout.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/stats/notifier/stats_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class SessionStatsPanel extends HookConsumerWidget {
  const SessionStatsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final connection = ref.watch(connectionNotifierProvider).valueOrNull;
    final statsAsync = ref.watch(statsNotifierProvider);
    final activeProxy = ref.watch(activeProxyNotifierProvider).valueOrNull;

    // Local session-start tracking: begin counting when we transition to
    // Connected, reset on disconnect.
    final sessionStart = useState<DateTime?>(null);
    final ticker = useState(0);

    useEffect(() {
      if (connection is Connected && sessionStart.value == null) {
        sessionStart.value = DateTime.now();
      } else if (connection is Disconnected) {
        sessionStart.value = null;
      }
      return null;
    }, [connection.runtimeType]);

    useEffect(() {
      final timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => ticker.value = ticker.value + 1,
      );
      return timer.cancel;
    }, const []);

    Widget body;
    if (connection is Connected) {
      final start = sessionStart.value;
      final elapsed = start != null
          ? DateTime.now().difference(start)
          : Duration.zero;

      final stats = statsAsync.valueOrNull;
      final downTotal = stats?.transport.downlinkTotal.toInt() ?? 0;
      final upTotal = stats?.transport.uplinkTotal.toInt() ?? 0;
      final downSpeed = stats?.transport.downlink.toInt() ?? 0;
      final upSpeed = stats?.transport.uplink.toInt() ?? 0;
      final latencyMs = activeProxy?.urlTestDelay ?? 0;

      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Center(child: body),
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
}
