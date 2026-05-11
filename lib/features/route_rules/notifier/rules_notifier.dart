import 'dart:convert';
import 'dart:io';

import 'package:dartx/dartx_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'rules_notifier.g.dart';

@riverpod
class RulesNotifier extends _$RulesNotifier with AppLogger {
  late File file;

  // family_vpn: Reality transport is TCP-only, so QUIC (UDP/443) packets can
  // never reach the proxy. When a browser/app tries QUIC first (FB, Google,
  // etc.) the connection just times out, *then* falls back to HTTP/2 — that's
  // the "site won't load" / "image preview missing" symptom. Force the
  // fallback to happen immediately by blocking QUIC at the route layer.
  static const _familyVpnDefaultRuleName = 'Block QUIC (family_vpn default)';

  Rule _buildDefaultBlockQuicRule() {
    return Rule()
      ..name = _familyVpnDefaultRuleName
      ..outbound = Outbound.block
      ..network = Network.udp
      ..portRanges.add('443')
      ..protocols.add(Protocol.quic)
      ..enabled = true
      ..listOrder = 0;
  }

  @override
  List<Rule> build() {
    final directories = ref.watch(appDirectoriesProvider).requireValue;
    file = File('${directories.baseDir.path}/route_rule.proto');
    final existing = file.existsSync()
        ? RouteRule.fromBuffer(file.readAsBytesSync()).rules
        : <Rule>[];
    if (!existing.any((r) => r.name == _familyVpnDefaultRuleName)) {
      // Insert at the top so it runs before any user-defined rule.
      final reordered = [_buildDefaultBlockQuicRule(), ...existing];
      for (var i = 0; i < reordered.length; i++) {
        reordered[i].listOrder = i;
      }
      // Best-effort persist; if it fails, in-memory state is still correct
      // for this run.
      try {
        if (!file.parent.existsSync()) {
          file.parent.createSync(recursive: true);
        }
        file.writeAsBytesSync(RouteRule(rules: reordered).writeToBuffer());
      } catch (_) {}
      return reordered;
    }
    return existing;
  }

  Future<void> addRule(Rule rule) async {
    final current = state;
    assert(rule.hasName() && rule.hasOutbound());
    rule
      ..listOrder = current.length
      ..enabled = true;
    state = [...current, rule];
    await _updateFile();
  }

  Future<void> updateRule(Rule rule) async {
    final current = state;
    final index = current.indexWhere((element) => element.listOrder == rule.listOrder);
    if (index == -1) return;
    current[index] = rule;
    state = current.toList();
    await _updateFile();
  }

  Future<void> deleteRule(int listOrder) async {
    final current = state;
    state = _updateListOrder(current.where((element) => element.listOrder != listOrder).toList());
    await _updateFile();
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    final current = state;
    final rule = current.removeAt(oldIndex);
    current.insert(oldIndex < newIndex ? newIndex - 1 : newIndex, rule);
    state = _updateListOrder(current).toList();
    await _updateFile();
  }

  Future<void> updateEnabled(bool enabled, int listOrder) async {
    final current = state;
    current.firstWhere((rule) => rule.listOrder == listOrder).enabled = enabled;
    state = current.toList();
    await _updateFile();
  }

  //export Clipboard
  Future<bool> exportJsonToClipboard() async {
    final t = ref.read(translationsProvider).requireValue;
    try {
      final routeRules = RouteRule(rules: state);
      await Clipboard.setData(ClipboardData(text: jsonEncode(routeRules.writeToJson())));
      ref.read(inAppNotificationControllerProvider).showSuccessToast(t.common.msg.export.clipboard.success);
      return true;
    } on PlatformException {
      ref
          .read(inAppNotificationControllerProvider)
          .showInfoToast(t.common.msg.export.clipboard.contentTooLarge, duration: const Duration(seconds: 5));
      return false;
    } catch (e, st) {
      loggy.warning("error exporting route rules to clipboard", e, st);
      ref.read(inAppNotificationControllerProvider).showErrorToast(t.common.msg.export.clipboard.failure);
      return false;
    }
  }

  //import Clipboard
  Future<bool> importRulesFromClipboard() async {
    final t = ref.read(translationsProvider).requireValue;
    try {
      final input = await Clipboard.getData(Clipboard.kTextPlain).then((value) => value?.text);
      if (input == null) return false;
      final routeRules = RouteRule.fromJson(jsonDecode(input) as String);
      state = routeRules.rules;
      await _updateFile();
      ref.read(inAppNotificationControllerProvider).showSuccessToast(t.common.msg.import.success);
      return true;
    } catch (e, st) {
      loggy.warning("error importing route rules from clipboard", e, st);
      ref.read(inAppNotificationControllerProvider).showErrorToast(t.common.msg.import.failure);
      return false;
    }
  }

  //export JSON
  Future<bool> saveRulesAsJsonFile() async {
    final t = ref.read(translationsProvider).requireValue;
    try {
      final bytes = utf8.encode(RouteRule(rules: state).writeToJson());
      final outputFile = await FilePicker.platform.saveFile(
        fileName: 'route_rules.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );
      if (outputFile == null) return false;
      if (PlatformUtils.isDesktop) {
        final file = File(outputFile);
        if (file.extension != '.json') return false;
        if (!await file.exists()) await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
      }
      ref.read(inAppNotificationControllerProvider).showSuccessToast(t.common.msg.export.file.success);
      return true;
    } catch (e, st) {
      loggy.warning("error exporting route rules to json file", e, st);
      ref.read(inAppNotificationControllerProvider).showErrorToast(t.common.msg.export.file.failure);
      return false;
    }
  }

  //import JSON
  Future<bool> importRulesFromJsonFile() async {
    final t = ref.read(translationsProvider).requireValue;
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
      if (result == null) return false;
      final file = File(result.files.single.path!);
      if (!await file.exists()) return false;
      final bytes = await file.readAsBytes();
      final routeRules = RouteRule.fromJson(utf8.decode(bytes));
      state = routeRules.rules;
      await _updateFile();
      ref.read(inAppNotificationControllerProvider).showSuccessToast(t.common.msg.import.success);
      return true;
    } catch (e, st) {
      loggy.warning("error importing route rules from json file", e, st);
      ref.read(inAppNotificationControllerProvider).showErrorToast(t.common.msg.import.failure);
      return false;
    }
  }

  Future<void> resetRules() async {
    if (await file.exists()) {
      await file.delete(recursive: true);
      state = <Rule>[];
    }
  }

  Future<void> _updateFile() async {
    if (!await file.exists()) {
      await file.parent.create(recursive: true);
    }
    final sortedRules = state..sort((a, b) => a.listOrder.compareTo(b.listOrder));
    final routeRules = RouteRule(rules: sortedRules);
    await file.writeAsBytes(routeRules.writeToBuffer());
  }

  List<Rule> _updateListOrder(List<Rule> rules) {
    for (var i = 0; i < rules.length; i++) {
      rules[i].listOrder = i;
    }
    return rules;
  }
}
