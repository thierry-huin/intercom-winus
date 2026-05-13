import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, Clipboard, ClipboardData;
import 'package:flutter_markdown/flutter_markdown.dart';

import '../theme/app_theme.dart';

/// Screen that displays the bundled user manual (`assets/user_manual.md`)
/// rendered as Markdown. The top bar offers a "Copy to clipboard" action so
/// the user can paste the manual into another app (Notes, email, …) when
/// they want a local copy.
class ManualScreen extends StatefulWidget {
  const ManualScreen({super.key});

  @override
  State<ManualScreen> createState() => _ManualScreenState();
}

class _ManualScreenState extends State<ManualScreen> {
  String? _content;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final text = await rootBundle.loadString('assets/user_manual.md');
      if (!mounted) return;
      setState(() => _content = text);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  Future<void> _copy() async {
    if (_content == null) return;
    await Clipboard.setData(ClipboardData(text: _content!));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Manual copied to clipboard'),
      duration: Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('User Manual'),
        actions: [
          IconButton(
            tooltip: 'Copy markdown to clipboard',
            icon: const Icon(Icons.copy),
            onPressed: _content == null ? null : _copy,
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not load the manual:\n$_error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              ),
            )
          : _content == null
              ? const Center(
                  child: CircularProgressIndicator(
                      color: AppColors.pressedBlueLight),
                )
              : Markdown(
                  data: _content!,
                  selectable: true,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  styleSheet: MarkdownStyleSheet(
                    p: const TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: AppColors.textPrimary),
                    h1: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary),
                    h2: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: AppColors.pressedBlueLight),
                    h3: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary),
                    blockquote: const TextStyle(
                        fontSize: 13,
                        fontStyle: FontStyle.italic,
                        color: AppColors.textSecondary),
                    blockquoteDecoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(6),
                      border: const Border(
                        left: BorderSide(
                            color: AppColors.pressedBlue, width: 3),
                      ),
                    ),
                    blockquotePadding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                    code: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        backgroundColor: AppColors.backgroundAlt),
                    codeblockDecoration: BoxDecoration(
                      color: AppColors.backgroundAlt,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.border),
                    ),
                    codeblockPadding: const EdgeInsets.all(10),
                    tableHead: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary),
                    tableBody: const TextStyle(
                        fontSize: 13, color: AppColors.textPrimary),
                    tableBorder: TableBorder.all(color: AppColors.border),
                    tableCellsPadding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 6),
                    listBullet: const TextStyle(color: AppColors.textPrimary),
                  ),
                ),
    );
  }
}
