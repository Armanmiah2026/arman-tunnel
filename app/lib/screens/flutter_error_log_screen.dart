import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/error_capture_service.dart';
import '../theme/snapdark_theme.dart';
import '../widgets/app_toast.dart';
import '../widgets/ui/snapdark_controls.dart';

/// Reads [ErrorCapture]'s in-memory buffer plus the persisted log file, so
/// runtime errors can be inspected directly on the phone without adb.
class FlutterErrorLogScreen extends StatefulWidget {
  const FlutterErrorLogScreen({super.key});

  @override
  State<FlutterErrorLogScreen> createState() => _FlutterErrorLogScreenState();
}

class _FlutterErrorLogScreenState extends State<FlutterErrorLogScreen> {
  Future<void> _copyAll() async {
    final text = await ErrorCapture.instance.fullLogText();
    if (text.trim().isEmpty) {
      if (mounted) AppToast.warning(context, 'Nothing to copy');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) AppToast.success(context, 'Error log copied');
  }

  Future<void> _clear() async {
    await ErrorCapture.instance.clearAll();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.scaffoldBg,
      appBar: AppBar(
        title: ValueListenableBuilder<int>(
          valueListenable: ErrorCapture.instance.revision,
          builder: (_, count, __) => Text('Error Logs ($count)'),
        ),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_rounded),
            onPressed: _copyAll,
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: _clear,
          ),
          const SizedBox(width: SnapDarkTokens.gapXs),
        ],
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: t.pageGradient,
          ),
        ),
        child: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: SnapDarkTokens.maxContentWidth,
              ),
              child: ValueListenableBuilder<int>(
                valueListenable: ErrorCapture.instance.revision,
                builder: (_, __, ___) => FutureBuilder<String>(
                  future: ErrorCapture.instance.fullLogText(),
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return Center(
                        child: CircularProgressIndicator(color: t.accent),
                      );
                    }
                    final text = (snap.data ?? '').trim();
                    if (text.isEmpty) {
                      return const SnapDarkEmptyState(
                        icon: Icons.verified_rounded,
                        title: 'No errors captured',
                        message: 'Uncaught Dart exceptions and zone errors would '
                            'appear here.',
                        positive: true,
                      );
                    }
                    // One selectable block per captured error; the marker is
                    // written by ErrorCapture as "──[timestamp".
                    final blocks = text
                        .split(RegExp(r'\n(?=──\[\d{4}-)'))
                        .map((b) => b.trim())
                        .where((b) => b.isNotEmpty)
                        .toList()
                        .reversed
                        .toList();
                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(
                        SnapDarkTokens.pageInset,
                        SnapDarkTokens.gapMd,
                        SnapDarkTokens.pageInset,
                        SnapDarkTokens.gapXxl,
                      ),
                      itemCount: blocks.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: SnapDarkTokens.gapSm),
                      itemBuilder: (_, i) => SnapDarkCard(
                        radius: SnapDarkTokens.radiusMd,
                        padding: const EdgeInsets.all(SnapDarkTokens.gapMd),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.bug_report_outlined,
                                  size: 13,
                                  color: t.alert,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'CRASH ${blocks.length - i}',
                                  style: t.overline,
                                ),
                              ],
                            ),
                            const SizedBox(height: SnapDarkTokens.gapSm),
                            SelectableText(
                              blocks[i],
                              style: t.mono(
                                size: 10.5,
                                weight: FontWeight.w500,
                                color: t.textSecondary,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
