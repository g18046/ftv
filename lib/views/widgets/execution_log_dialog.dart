import 'package:flutter/material.dart';
import '../../services/js_engine_service.dart';

/// 运行逻辑与 JS 执行日志可视化浮窗/弹窗
class ExecutionLogDialog extends StatelessWidget {
  final JsEngineService jsEngine;

  const ExecutionLogDialog({super.key, required this.jsEngine});

  static void show(BuildContext context, JsEngineService jsEngine) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.75,
        child: ExecutionLogDialog(jsEngine: jsEngine),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.92),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.terminal, color: Colors.greenAccent),
                  SizedBox(width: 8),
                  Text(
                    'QuickJS 引擎运行可视化日志',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: jsEngine.clearLogs,
                    icon: const Icon(Icons.delete_outline, size: 18, color: Colors.grey),
                    label: const Text('清空', style: TextStyle(color: Colors.grey)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ],
          ),
          const Divider(color: Colors.grey),
          Expanded(
            child: ValueListenableBuilder<List<JsLogEntry>>(
              valueListenable: jsEngine.logNotifier,
              builder: (context, logs, _) {
                if (logs.isEmpty) {
                  return const Center(
                    child: Text(
                      '暂无运行日志，将在执行 JS 接口或网络请求时自动记录...',
                      style: TextStyle(color: Colors.grey),
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: logs.length,
                  itemBuilder: (context, index) {
                    final log = logs[logs.length - 1 - index]; // 倒序呈现最新日志
                    Color levelColor = Colors.greenAccent;

                    if (log.level == 'ERROR' || log.level == 'HTTP-ERR') {
                      levelColor = Colors.redAccent;
                    } else if (log.level == 'MODULE' || log.level == 'HTTP-REQ') {
                      levelColor = Colors.cyanAccent;
                    } else if (log.level == 'EXEC' || log.level == 'CALL') {
                      levelColor = Colors.amberAccent;
                    }

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Text(
                        log.toString(),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: levelColor,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
