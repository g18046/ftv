import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/js_engine_service.dart';

/// 运行逻辑与 JS 执行日志可视化独立全屏页面（单例打开、支持正则过滤、跨行选中与全选复制）
class ExecutionLogDialog extends StatefulWidget {
  final JsEngineService jsEngine;

  const ExecutionLogDialog({super.key, required this.jsEngine});

  static bool _isOpen = false;

  static void show(BuildContext context, JsEngineService jsEngine) {
    if (_isOpen) return;
    _isOpen = true;
    Navigator.of(context, rootNavigator: true)
        .push(
          MaterialPageRoute(
            builder: (_) => ExecutionLogDialog(jsEngine: jsEngine),
          ),
        )
        .whenComplete(() => _isOpen = false);
  }

  @override
  State<ExecutionLogDialog> createState() => _ExecutionLogDialogState();
}

class _ExecutionLogDialogState extends State<ExecutionLogDialog> {
  final TextEditingController _filterCtrl = TextEditingController();
  String _filterPattern = '';

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  Color _levelColor(String level) {
    switch (level) {
      case 'ERROR':
      case 'HTTP-ERR':
        return const Color(0xFFFF6B6B);
      case 'MODULE':
      case 'HTTP-REQ':
        return const Color(0xFF4DD0E1);
      case 'EXEC':
      case 'CALL':
        return const Color(0xFFFFD54F);
      case 'RESULT':
        return const Color(0xFF64B5F6);
      default:
        return const Color(0xFF69F0AE);
    }
  }

  String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  List<JsLogEntry> _applyFilter(List<JsLogEntry> logs) {
    final pat = _filterPattern.trim();
    if (pat.isEmpty) return logs;
    try {
      final re = RegExp(pat, caseSensitive: false);
      return logs
          .where((e) => re.hasMatch('[${e.level}] ${e.message}'))
          .toList();
    } catch (_) {
      final lower = pat.toLowerCase();
      return logs
          .where((e) =>
              '[${e.level}] ${e.message}'.toLowerCase().contains(lower))
          .toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.terminal, color: Colors.greenAccent, size: 20),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'QuickJS 运行日志',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '复制当前筛选日志',
            icon: const Icon(Icons.copy_all, color: Colors.white70, size: 20),
            onPressed: () {
              final filtered = _applyFilter(widget.jsEngine.logNotifier.value);
              final text = filtered
                  .map((e) => '[${_formatTime(e.time)}] [${e.level}] ${e.message}')
                  .join('\n');
              if (text.isEmpty) return;
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('已复制 ${filtered.length} 条运行日志'),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
          TextButton.icon(
            onPressed: widget.jsEngine.clearLogs,
            icon: const Icon(Icons.delete_outline, size: 18, color: Colors.white70),
            label: const Text('清空', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: const Color(0xFF161B22),
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: TextField(
                controller: _filterCtrl,
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
                onChanged: (v) => setState(() => _filterPattern = v),
                decoration: InputDecoration(
                  hintText: '正则/关键字过滤 (如: flutter|com)...',
                  hintStyle: const TextStyle(color: Colors.white38, fontSize: 12.5),
                  prefixIcon: const Icon(Icons.filter_alt_outlined,
                      color: Colors.white54, size: 18),
                  suffixIcon: _filterPattern.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear,
                              color: Colors.white54, size: 18),
                          onPressed: () {
                            _filterCtrl.clear();
                            setState(() => _filterPattern = '');
                          },
                        )
                      : null,
                  isDense: true,
                  filled: true,
                  fillColor: const Color(0xFF0D1117),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF30363D)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF30363D)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Colors.greenAccent),
                  ),
                ),
              ),
            ),
            Expanded(
              child: ValueListenableBuilder<List<JsLogEntry>>(
                valueListenable: widget.jsEngine.logNotifier,
                builder: (context, logs, _) {
                  final filtered = _applyFilter(logs);
                  if (filtered.isEmpty) {
                    return Center(
                      child: Text(
                        _filterPattern.trim().isEmpty
                            ? '暂无运行日志，将在执行 JS 接口或网络请求时自动记录...'
                            : '未匹配到符合 "$_filterPattern" 的日志',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    );
                  }

                  return SelectionArea(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const Divider(
                        height: 12,
                        color: Colors.white10,
                      ),
                      itemBuilder: (context, index) {
                        final log = filtered[filtered.length - 1 - index];
                        final lvColor = _levelColor(log.level);
                        final timeStr = _formatTime(log.time);

                        return Text.rich(
                          TextSpan(
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12.5,
                              height: 1.45,
                            ),
                            children: [
                              TextSpan(
                                text: '[$timeStr] ',
                                style: const TextStyle(color: Colors.white38),
                              ),
                              TextSpan(
                                text: '[${log.level}] ',
                                style: TextStyle(
                                  color: lvColor,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              TextSpan(
                                text: log.message,
                                style: TextStyle(
                                  color: (log.level == 'ERROR' ||
                                          log.level == 'HTTP-ERR')
                                      ? const Color(0xFFFFB4B4)
                                      : Colors.white.withValues(alpha: 0.92),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
