import 'package:flutter_qjs/flutter_qjs.dart';

/// JS 全局 console 桥接能力
class ConsoleBridge {
  static Future<void> inject(
    IsolateQjs engine, {
    required void Function(String level, String message) onLog,
  }) async {
    final setGlobal = (await engine.evaluate('(key, val) => { globalThis[key] = val; }')) as JSInvokable;

    await setGlobal.invoke([
      '__nativeLog',
      IsolateFunction((String msg) {
        onLog('JS-LOG', msg);
      }),
    ]);

    setGlobal.free();

    // 注入 JS 环境下的 console 对象
    await engine.evaluate('''
      globalThis.console = {
        log: (...args) => globalThis.__nativeLog(args.map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ')),
        error: (...args) => globalThis.__nativeLog('[ERROR] ' + args.map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ')),
        info: (...args) => globalThis.__nativeLog('[INFO] ' + args.map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ')),
        warn: (...args) => globalThis.__nativeLog('[WARN] ' + args.map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' '))
      };
    ''');
  }
}
