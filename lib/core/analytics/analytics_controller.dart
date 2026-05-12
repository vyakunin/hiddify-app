import 'package:hiddify/utils/custom_loggers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'analytics_controller.g.dart';

const String enableAnalyticsPrefKey = "enable_analytics";

// Sentry/analytics removed in the family_vpn fork — relatives don't need
// crash reporting and we don't run a Sentry org. Keep the provider as a
// no-op stub so existing call sites (bootstrap, intro page, settings tile)
// still compile.
@Riverpod(keepAlive: true)
class AnalyticsController extends _$AnalyticsController with AppLogger {
  @override
  Future<bool> build() async => false;

  Future<void> enableAnalytics() async {
    // no-op
  }

  Future<void> disableAnalytics() async {
    // no-op
  }
}
