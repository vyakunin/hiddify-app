import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:hiddify/singbox/model/core_status.dart';

class CoreInterface {
  late CoreClient fgClient;
  late CoreClient bgClient;

  Future<String> setup(Directories directories, bool debug, int mode) async {
    return "";
  }

  Future<CoreStatus> setupBackground(String path, String name) async {
    return const CoreStarted();
  }

  Future<bool> restart(String path, String name) async {
    return false;
  }

  Future<bool> stop() async {
    return false;
  }

  Future<bool> isBgClientAvailable() async {
    return true;
  }

  bool isSingleChannel() {
    // return true;
    return fgClient == bgClient;
  }

  Future<bool> resetTunnel() async {
    return false;
  }

  Future<bool> isActiveFg() async {
    return true;
  }

  Future<bool> isActiveBg() async {
    return true;
  }

  // family_vpn fork: trigger the Android system VPN-permission dialog without
  // starting the VPN service. Used for first-launch pre-request and for
  // auto-retry after the core surfaces "permission denied" on connect.
  // Returns true if perm was granted (or already granted), false on denial /
  // unsupported platform. Default impl is a no-op returning true (desktop).
  Future<bool> requestVpnPermission() async {
    return true;
  }

  // family_vpn fork: Kotlin-authoritative tunnel-up timestamp (ms since
  // epoch). Returns 0 when the tunnel is not running. Used by the session
  // stats panel so the timer survives Activity rebuilds / Dart stream
  // re-subscriptions (the connection-status stream emits spurious
  // Disconnected on resume which would otherwise reset the visible timer).
  // Default impl is 0 (desktop has no Kotlin tunnel).
  Future<int> getConnectedSinceMs() async {
    return 0;
  }

  bool isInitialized() {
    try {
      bgClient; // touch it
      return true;
    } catch (_) {
      return false;
    }
  }
}
