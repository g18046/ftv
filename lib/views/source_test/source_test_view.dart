import 'dart:convert';
import 'package:flutter/material.dart';
import '../../repositories/site_repository.dart';
import '../../services/config_service.dart';

class SourceTestView extends StatefulWidget {
  final SiteRepository repository;

  const SourceTestView({super.key, required this.repository});

  @override
  State<SourceTestView> createState() => _SourceTestViewState();
}

class _SourceTestViewState extends State<SourceTestView> {
  final ConfigService _configService = ConfigService();
  final TextEditingController _jsUrlController = TextEditingController(
    text: 'http://192.168.5.4:5000/src/js/极速追剧.js',
  );
  final TextEditingController _searchKeywordController = TextEditingController(
    text: '凡人修仙传',
  );

  String _jsStatusText = '尚未初始化 JS 源';
  String _jsOutputResult = '暂无调试输出数据';
  bool _isJsLoading = false;

  @override
  void dispose() {
    _jsUrlController.dispose();
    _searchKeywordController.dispose();
    super.dispose();
  }

  Future<void> _handleLoadJsSource() async {
    final jsUrl = _jsUrlController.text.trim();
    if (jsUrl.isEmpty) return;

    setState(() {
      _isJsLoading = true;
      _jsStatusText = '正在抓取 JS 源码...';
      _jsOutputResult = '正在解析依赖与载入引擎...';
    });

    try {
      String jsCode = '';
      if (jsUrl.startsWith('http://') || jsUrl.startsWith('https://')) {
        jsCode = await _configService.loadOnlineConfigRaw(jsUrl);
      } else {
        jsCode = await _configService.loadOnlineConfigRaw(jsUrl);
        if (jsCode.isEmpty) {
          final file = Uri.parse(jsUrl).toFilePath();
          jsCode = await _configService.loadOnlineConfigRaw(file);
        }
      }

      final res = await widget.repository.jsEngine.loadJsSource(jsCode, baseUrl: jsUrl);

      setState(() {
        _isJsLoading = false;
        _jsStatusText = 'JS 源初始化成功！';
        _jsOutputResult = '加载结果:\n${res.toString()}';
      });
    } catch (e) {
      setState(() {
        _isJsLoading = false;
        _jsStatusText = 'JS 源初始化失败';
        _jsOutputResult = '错误原因:\n$e';
      });
    }
  }

  Future<void> _handleCallJsMethod(String method, [List<dynamic> args = const []]) async {
    if (!widget.repository.jsEngine.isInitialized) {
      setState(() {
        _jsStatusText = '请先点击“加载并运行 JS 源”初始化！';
      });
      return;
    }

    setState(() {
      _isJsLoading = true;
      _jsStatusText = '正在执行 $method()...';
    });

    try {
      final res = await widget.repository.jsEngine.callMethod(method, args);
      const encoder = JsonEncoder.withIndent('  ');
      final prettyJson = res is Map || res is List ? encoder.convert(res) : res.toString();

      setState(() {
        _isJsLoading = false;
        _jsStatusText = '$method() 执行成功';
        _jsOutputResult = '[$method 结果]:\n$prettyJson';
      });
    } catch (e) {
      setState(() {
        _isJsLoading = false;
        _jsStatusText = '$method() 执行出错';
        _jsOutputResult = '报错信息:\n$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('多模块 JS 源运行调试'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: _isJsLoading ? Colors.orange.shade50 : Colors.green.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Text('状态: $_jsStatusText', style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _jsUrlController,
              decoration: const InputDecoration(
                labelText: '测试 JS 源路径 (支持 D:/code/ftv/测试源/src/js/极速追剧.js 或 局域网 URL)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _isJsLoading ? null : _handleLoadJsSource,
              icon: const Icon(Icons.play_arrow),
              label: const Text('加载并运行 JS 源'),
            ),
            const Divider(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _isJsLoading ? null : () => _handleCallJsMethod('home', [true]),
                  icon: const Icon(Icons.category),
                  label: const Text('home(分类)'),
                ),
                OutlinedButton.icon(
                  onPressed: _isJsLoading ? null : () => _handleCallJsMethod('homeVod'),
                  icon: const Icon(Icons.movie),
                  label: const Text('homeVod(推荐)'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchKeywordController,
                    decoration: const InputDecoration(
                      labelText: '搜索关键词',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _isJsLoading
                      ? null
                      : () => _handleCallJsMethod('search', [_searchKeywordController.text.trim(), false, 1]),
                  icon: const Icon(Icons.search),
                  label: const Text('search(搜索)'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('调试日志与 JSON 输出:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade400),
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.black87,
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _jsOutputResult,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Colors.greenAccent,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
