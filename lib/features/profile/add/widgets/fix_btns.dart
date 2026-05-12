import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/profile/add/widgets/widgets.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class FixBtns extends ConsumerWidget {
  const FixBtns({super.key, required this.height});
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;

    // QR scanner button removed in family_vpn fork — relatives import via
    // the baked sub URL on first launch, not by scanning QR codes.
    return Row(
      children: [
        const Gap(AddProfileModalConst.fixBtnsGap),
        FixBtn(
          key: const ValueKey('add_from_clipboard_button'),
          height: height,
          title: t.common.clipboard,
          icon: Icons.content_paste,
          onTap: () async {
            final cr = await Clipboard.getData(Clipboard.kTextPlain).then((value) => value?.text ?? '');
            ref.read(addProfileNotifierProvider.notifier).addClipboard(cr);
          },
        ),
        const Gap(AddProfileModalConst.fixBtnsGap),
        FixBtn(
          key: const ValueKey('add_manually_button'),
          height: height,
          title: t.common.manually,
          icon: Icons.add,
          onTap: () {
            ref.read(addProfilePageNotifierProvider.notifier).goManual();
          },
        ),
        const Gap(AddProfileModalConst.fixBtnsGap),
      ],
    );
  }
}
