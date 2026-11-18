import 'package:flutter_qjs/flutter_qjs.dart';
import '../services/local_http_server.dart';
import 'console_bridge.dart';
import 'http_bridge.dart';
import 'storage_bridge.dart';

/// FTV 影视精简型 JS 运行环境注入器
/// 遵循 《FTV 影视 JS Spider 与配置开发文档.md》 核心规范：
/// 1. Console 全局日志桥接
/// 2. req / http / fetch 异步网络通信桥接
/// 3. local 本地持久化存储 (local.get / local.set / local.delete)
/// 4. 定时器微任务 (setTimeout / clearTimeout)
/// 5. 本地服务与代理工具 (getPort, getProxy, js2Proxy)
class JsBridge {
  static Future<void> injectAll(
    IsolateQjs engine, {
    required void Function(String level, String message) onLog,
  }) async {
    // 1. 注入 Console
    await ConsoleBridge.inject(engine, onLog: onLog);

    // 2. 注入 HTTP / req / fetch 异步通信
    await HttpBridge.inject(engine, onLog: onLog);

    // 3. 注入 Local Storage 本地持久化存储
    await StorageBridge.inject(engine, onLog: onLog);

    // 4. 动态写入当前活跃的本地 HTTP 端口
    await engine
        .evaluate('globalThis.__serverPort = ${LocalHttpServer().port};');

    // 5. 注入精简核心环境工具 (去除冗余的加解密、Base64 与 DOM 杂项函数)
    await engine.evaluate(r'''
      // ─────────────────────────────────────────────────────────────
      // 1. 定时器微任务 Polyfill
      // ─────────────────────────────────────────────────────────────
      if (typeof globalThis.setTimeout === 'undefined') {
        let __timerSeq = 1;
        const __activeTimers = {};

        globalThis.setTimeout = function(fn, delay) {
          const id = __timerSeq++;
          __activeTimers[id] = true;
          Promise.resolve().then(() => {
            if (__activeTimers[id]) {
              delete __activeTimers[id];
              try { fn(); } catch(e) { console.error('setTimeout error:', e); }
            }
          });
          return id;
        };

        globalThis.clearTimeout = function(id) {
          delete __activeTimers[id];
        };
      }

      // ─────────────────────────────────────────────────────────────
      // 2. 本地端口与代理工具 (getPort, getProxy, js2Proxy)
      // ─────────────────────────────────────────────────────────────
      globalThis.getPort = function() {
        return globalThis.__serverPort || 9978;
      };

      globalThis.getProxy = function(local) {
        return 'http://${LocalHttpServer().hostIp}:' + globalThis.getPort() + '/proxy?do=js';
      };

      globalThis.js2Proxy = function(dynamic, siteType, siteKey, url, headers) {
        let base = 'http://${LocalHttpServer().hostIp}:' + globalThis.getPort() + '/proxy';
        return base + '?do=js&site=' + encodeURIComponent(siteKey || '') + '&url=' + encodeURIComponent(url || '');
      };
    ''');
  }

  static Future<void> clearAll(IsolateQjs engine) async {
    try {
      await engine.evaluate(r'''
        delete globalThis.console;
        delete globalThis.req;
        delete globalThis.http;
        delete globalThis.fetch;
        delete globalThis.local;
        delete globalThis.spider;
        delete globalThis.exports;
        delete globalThis.module;
        delete globalThis.window;
        delete globalThis.CryptoJS;
        delete globalThis.cheerio;
        delete globalThis.getPort;
        delete globalThis.getProxy;
        delete globalThis.js2Proxy;
        delete globalThis.__serverPort;
        delete globalThis.__nativeLog;
        delete globalThis.__triggerNativeHttp;
        delete globalThis.__nativeLocalGet;
        delete globalThis.__nativeLocalSet;
        delete globalThis.__nativeLocalDelete;

        if (typeof gc === 'function') {
          gc();
        }
      ''');
    } catch (_) {}
  }
}
