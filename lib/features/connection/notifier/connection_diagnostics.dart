// family_vpn fork: periodic structured logging that makes "stuck Connected"
// failures diagnoseable from the shared log file alone.
//
// Why this exists: when an upstream data-plane host disappears (e.g. the
// Berlin homeserver going offline while another VPS is still up in the same
// subscription), the singbox core does NOT report CoreStopped — it stays in
// CoreStarted indefinitely while every outbound dial fails. The UI keeps
// showing "Подключено" with 0 B/s; the user sees a stuck app; the operator
// gets a screenshot but no signal about *why*.
//
// What this notifier emits (to the standard app.log):
//   • on every connection-state transition: detailed shape (status, outbound,
//     delay, in/out byte totals) so the boundary moment is captured
//   • while Connected: heartbeat every 30s with the same shape
//   • when ≥3 heartbeats in a row show flat byte totals AND a connected
//     status: WARNING "STUCK_CONNECTED" so a quick grep finds the symptom
//
// Total cost: one timer + a few log lines/min. Strictly diagnostic — no
// retry/auto-recover logic here; that's a separate piece of work.
//
// Hand-rolled Provider (not @Riverpod-generated) so it doesn't depend on the
// build_runner step — keeps the diagnostic landed even when running the app
// from a stale generator state.

import 'dart:async';

import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/stats/notifier/stats_notifier.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:loggy/loggy.dart';

const _heartbeatInterval = Duration(seconds: 30);
const _stuckConsecutiveHeartbeats = 3;

final connectionDiagnosticsProvider = Provider<ConnectionDiagnostics>((ref) {
  final diag = ConnectionDiagnostics(ref);
  ref.onDispose(diag.dispose);
  return diag;
});

class ConnectionDiagnostics {
  ConnectionDiagnostics(this._ref) {
    _attach();
  }

  final Ref _ref;
  final Loggy _loggy = Loggy<AppLogger>("ConnectionDiagnostics");

  Timer? _timer;
  ConnectionStatus? _lastStatus;
  int _lastUplinkTotal = 0;
  int _lastDownlinkTotal = 0;
  int _flatHeartbeats = 0;
  DateTime? _connectedSince;

  void _attach() {
    _ref.listen<AsyncValue<ConnectionStatus>>(
      connectionNotifierProvider,
      (prev, next) {
        final prevStatus = prev?.valueOrNull;
        final nextStatus = next.valueOrNull;
        if (nextStatus == null || prevStatus == nextStatus) return;
        _onStatusTransition(prevStatus, nextStatus);
      },
      fireImmediately: true,
    );

    _timer = Timer.periodic(_heartbeatInterval, (_) => _heartbeat());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  void _onStatusTransition(ConnectionStatus? prev, ConnectionStatus next) {
    _lastStatus = next;
    final snap = _readSnapshot();
    final prevLabel = prev?.format() ?? "NONE";
    if (next is Connected) {
      _connectedSince = DateTime.now();
      _flatHeartbeats = 0;
      _lastUplinkTotal = snap.uplinkTotal;
      _lastDownlinkTotal = snap.downlinkTotal;
      _loggy.info(
        "transition $prevLabel→CONNECTED ${_formatSnapshot(snap)}",
      );
    } else if (next is Disconnected) {
      final wasConnectedFor = _connectedSince == null
          ? null
          : DateTime.now().difference(_connectedSince!);
      _connectedSince = null;
      _flatHeartbeats = 0;
      final failure = next.connectionFailure;
      final duration =
          wasConnectedFor == null ? "" : " after ${wasConnectedFor.inSeconds}s";
      if (failure != null) {
        _loggy.warning(
          "transition $prevLabel→DISCONNECTED$duration failure=$failure ${_formatSnapshot(snap)}",
        );
      } else {
        _loggy.info(
          "transition $prevLabel→DISCONNECTED$duration ${_formatSnapshot(snap)}",
        );
      }
    } else {
      _loggy.info(
        "transition $prevLabel→${next.format()} ${_formatSnapshot(snap)}",
      );
    }
  }

  void _heartbeat() {
    final status = _lastStatus;
    if (status is! Connected) return;

    final snap = _readSnapshot();
    final byteDelta =
        (snap.uplinkTotal - _lastUplinkTotal) + (snap.downlinkTotal - _lastDownlinkTotal);
    _lastUplinkTotal = snap.uplinkTotal;
    _lastDownlinkTotal = snap.downlinkTotal;

    if (byteDelta == 0) {
      _flatHeartbeats += 1;
    } else {
      _flatHeartbeats = 0;
    }

    final flatTag = _flatHeartbeats > 0 ? " flat=$_flatHeartbeats" : "";
    final aliveFor = _connectedSince == null
        ? ""
        : " uptime=${DateTime.now().difference(_connectedSince!).inSeconds}s";
    final line = "heartbeat$aliveFor$flatTag ${_formatSnapshot(snap)}";

    if (_flatHeartbeats >= _stuckConsecutiveHeartbeats) {
      // After ~90s of zero traffic on a Connected session, we are almost
      // certainly in the "stuck Connected" failure mode — the core thinks
      // it's up but the upstream host is unreachable and there's no
      // fall-over to the second host in the subscription. Loud-log so a
      // simple `grep STUCK_CONNECTED` on the shared file finds it.
      _loggy.warning("STUCK_CONNECTED $line");
    } else {
      _loggy.info(line);
    }
  }

  _DiagSnapshot _readSnapshot() {
    final statsAsync = _ref.read(statsNotifierProvider);
    final outboundAsync = _ref.read(activeProxyNotifierProvider);
    final profileAsync = _ref.read(activeProfileProvider);

    final stats = statsAsync.valueOrNull;
    final outbound = outboundAsync.valueOrNull;
    final profile = profileAsync.valueOrNull;

    return _DiagSnapshot(
      uplinkInst: stats?.uplink.toInt() ?? 0,
      downlinkInst: stats?.downlink.toInt() ?? 0,
      uplinkTotal: stats?.uplinkTotal.toInt() ?? 0,
      downlinkTotal: stats?.downlinkTotal.toInt() ?? 0,
      currentOutbound: stats?.currentOutbound ?? outbound?.tag ?? "",
      connectionsIn: stats?.connectionsIn ?? 0,
      connectionsOut: stats?.connectionsOut ?? 0,
      urlTestDelay: outbound?.urlTestDelay ?? 0,
      outboundHost: outbound?.host ?? "",
      outboundPort: outbound?.port ?? 0,
      groupSelected: outbound?.groupSelectedTag ?? "",
      profileName: profile?.name ?? "",
      profileLastUpdate: profile?.lastUpdate,
    );
  }

  String _formatSnapshot(_DiagSnapshot s) {
    final fields = <String>[
      "dn=${s.downlinkInst}B/s up=${s.uplinkInst}B/s",
      "dnTotal=${s.downlinkTotal} upTotal=${s.uplinkTotal}",
      if (s.urlTestDelay > 0) "delay=${s.urlTestDelay}ms",
      if (s.currentOutbound.isNotEmpty) "outbound=${s.currentOutbound}",
      if (s.outboundHost.isNotEmpty) "host=${s.outboundHost}:${s.outboundPort}",
      if (s.groupSelected.isNotEmpty && s.groupSelected != s.currentOutbound)
        "group=${s.groupSelected}",
      "conn=${s.connectionsIn}/${s.connectionsOut}",
      if (s.profileLastUpdate != null)
        "profileAge=${DateTime.now().difference(s.profileLastUpdate!).inMinutes}m",
    ];
    return fields.join(" ");
  }
}

class _DiagSnapshot {
  _DiagSnapshot({
    required this.uplinkInst,
    required this.downlinkInst,
    required this.uplinkTotal,
    required this.downlinkTotal,
    required this.currentOutbound,
    required this.connectionsIn,
    required this.connectionsOut,
    required this.urlTestDelay,
    required this.outboundHost,
    required this.outboundPort,
    required this.groupSelected,
    required this.profileName,
    required this.profileLastUpdate,
  });

  final int uplinkInst;
  final int downlinkInst;
  final int uplinkTotal;
  final int downlinkTotal;
  final String currentOutbound;
  final int connectionsIn;
  final int connectionsOut;
  final int urlTestDelay;
  final String outboundHost;
  final int outboundPort;
  final String groupSelected;
  final String profileName;
  final DateTime? profileLastUpdate;
}
