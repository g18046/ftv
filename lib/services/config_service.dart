import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import '../models/config_model.dart';

/// OK影视 / FongMi 原生点播配置服务
/// 深度支持：
/// 1. 绝对可访问的本地绝对路径 (file:///xxx/ 规范)
/// 2. 本地目录与离线 ZIP 包自动解压索引 (以内部 config.json 为基准推导全部 js/lib/config 相对路径)
/// 3. Android 手机外部存储 (/storage/emulated/0/Download/config.json) 优先映射与自动脱壳 (避开 /data/ 缓存孤岛)
/// 4. 远程 HTTP/HTTPS 配置 (自动跟随重定向并推导 baseUrl)
/// 5. clan://localhost/ 虚拟协议本地映射
/// 6. 容错 JSON 解析 (去注释/尾随逗号/Base64/UTF-8 BOM)
class ConfigService {
  late final Dio _dio;
  static const String _historyFileName = 'ftv_config_history.json';

  ConfigService() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': '*/*',
      },
    ));
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // 1. 本地包与文件选择器
  // ─────────────────────────────────────────────────────────────────────────────

  /// 调用系统选择器导入本地包 (.zip) 或配置文件 (.json)
  Future<ConfigLoadResult?> pickAndLoadConfig() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['zip', 'json', 'txt'],
      );

      if (file != null && file.path != null) {
        return await loadConfigFromPathOrUrl(file.path!);
      }
    } catch (e) {
      print('文件选择或读取失败: $e');
    }
    return null;
  }

  
  /// 将本地路径规范化为标准 file:/// 协议 URI
  static String toFileUri(String path) {
    String clean = path.trim().replaceAll('\\', '/');
    if (clean.startsWith('file://')) return clean;
    if (clean.startsWith('/')) {
      return 'file://$clean';
    }
    // Windows 盘符 D:/...
    return 'file:///$clean';
  }

  /// 将 file:/// 协议 URI 解析回本地操作系统路径
  static String fromFileUri(String uriStr) {
    String clean = uriStr.trim();
    if (!clean.startsWith('file://')) return clean.replaceAll('\\', '/');
    try {
      return Uri.parse(clean).toFilePath().replaceAll('\\', '/');
    } catch (_) {
      clean = clean.replaceFirst('file://', '');
      if (Platform.isWindows && RegExp(r'^/[a-zA-Z]:').hasMatch(clean)) {
        clean = clean.substring(1);
      }
      return clean.replaceAll('\\', '/');
    }
  }

/// 移除了不必要的全盘自动盲目探测，仅保留清晰的输入路径解析
  Future<String?> detectLocalConfigFile() async {
    return null; // 不再进行无谓的盲猜探测，以用户输入为准
  }

  /// 统一入口：根据用户输入的具体路径或链接精准加载
  Future<ConfigLoadResult?> loadConfigFromPathOrUrl(String pathOrUrl) async {
    String trimmed = pathOrUrl.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return await loadOnlineConfig(trimmed);
    }

    if (trimmed.startsWith('clan://localhost/')) {
      final activeConfig = await getActiveConfig();
      final pkgDir = activeConfig?.localPackageDir;
      if (pkgDir == null) return null;
      final rel = trimmed.replaceFirst('clan://localhost/', '');
      return await loadLocalFileConfig('$pkgDir/$rel');
    }

    String fsPath = fromFileUri(trimmed);

    if (fsPath.toLowerCase().endsWith('.zip')) {
      return await extractAndLoadZip(fsPath);
    }

    final dir = Directory(fsPath);
    if (await dir.exists()) {
      return await loadFromDirectory(fsPath);
    }

    final file = File(fsPath);
    if (await file.exists()) {
      return await loadLocalFileConfig(fsPath);
    }

    print('❌ 未能定位指定的配置源: $trimmed');
    return null;
  }

  /// 从单文件配置加载（严格以文件自身所在目录为准）
  Future<ConfigLoadResult?> loadLocalFileConfig(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('配置文件不存在: $filePath');
      }

      final content = await file.readAsString();
      final configMap = cleanAndParseJson(content);
      final parentDir = file.parent.path;
      final fileName = file.uri.pathSegments.isNotEmpty ? file.uri.pathSegments.last : 'config.json';

      return ConfigLoadResult(
        configMap: configMap,
        effectiveBaseUrl: toFileUri(file.path),
        localPackageDir: parentDir,
        type: ConfigType.localPackage,
        suggestedName: '本地配置: $fileName',
      );
    } catch (e) {
      print('加载本地配置文件失败: $e');
      return null;
    }
  }
  /// 从本地文件夹目录直接加载配置包 (如 D:/code/ok影视js源/my)
  Future<ConfigLoadResult?> loadFromDirectory(String dirPath) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        throw Exception('指定目录不存在: $dirPath');
      }

      print('📂 正在探测本地目录源: $dirPath');

      final candidates = [
        '$dirPath/config.json',
        '$dirPath/src/config.json',
        '$dirPath/dist/config.json',
        '$dirPath/config/config.json',
      ];

      File? targetFile;
      for (final p in candidates) {
        final f = File(p);
        if (await f.exists()) {
          targetFile = f;
          break;
        }
      }

      if (targetFile == null) {
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File && entity.path.toLowerCase().endsWith('.json')) {
            try {
              final content = await entity.readAsString();
              if (content.contains('"sites"') || content.contains("'sites'")) {
                targetFile = entity;
                break;
              }
            } catch (_) {}
          }
        }
      }

      if (targetFile == null) {
        throw Exception('目录内未检索到有效的 config.json: $dirPath');
      }

      final content = await targetFile.readAsString();
      final configMap = cleanAndParseJson(content);
      final folderName = dirPath.split('/').where((s) => s.isNotEmpty).last;

      final fileUri = toFileUri(targetFile.path);

      return ConfigLoadResult(
        configMap: configMap,
        effectiveBaseUrl: fileUri,
        localPackageDir: targetFile.parent.path,
        type: ConfigType.localPackage,
        suggestedName: '本地源: $folderName',
      );
    } catch (e) {
      print('加载本地目录失败: $e');
      return null;
    }
  }

  /// 解压本地 ZIP 压缩包，自动探测内部 config.json，构建绝对可访问的本地包沙盒环境
  Future<ConfigLoadResult?> extractAndLoadZip(String zipFilePath) async {
    try {
      final zipFile = File(zipFilePath);
      if (!await zipFile.exists()) {
        throw Exception('ZIP 文件不存在: $zipFilePath');
      }

      print('🚀 开始解压本地包: $zipFilePath');
      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // 计算提取沙盒根目录: <app_dir>/ftv_packages/<safe_name>/
      final baseDir = await _getPackagesBaseDirectory();
      final rawName = zipFile.uri.pathSegments.isNotEmpty
          ? zipFile.uri.pathSegments.last.replaceAll('.zip', '')
          : 'package_${DateTime.now().millisecondsSinceEpoch}';
      final safeName = rawName.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5_-]'), '_');
      final extractDir = Directory('${baseDir.path}/$safeName');

      if (!await extractDir.exists()) {
        await extractDir.create(recursive: true);
      }

      // 将压缩包内全部文件解压至本地沙盒
      for (final file in archive) {
        final filename = file.name.replaceAll('\\', '/');
        final outPath = '${extractDir.path}/$filename';
        if (file.isFile) {
          final outFile = File(outPath);
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        } else {
          await Directory(outPath).create(recursive: true);
        }
      }

      print('✅ 本地包解压完成，目标目录: ${extractDir.path}');

      // 深度定位 config.json
      final configCandidates = [
        '${extractDir.path}/config.json',
        '${extractDir.path}/src/config.json',
        '${extractDir.path}/dist/config.json',
        '${extractDir.path}/config/config.json',
      ];

      File? targetConfigFile;
      for (final candidate in configCandidates) {
        final f = File(candidate);
        if (await f.exists()) {
          targetConfigFile = f;
          break;
        }
      }

      if (targetConfigFile == null) {
        await for (final entity in extractDir.list(recursive: true)) {
          if (entity is File && entity.path.toLowerCase().endsWith('.json')) {
            try {
              final content = await entity.readAsString();
              if (content.contains('"sites"') || content.contains("'sites'")) {
                targetConfigFile = entity;
                print('🔍 全盘搜寻匹配到配置文件: ${entity.path}');
                break;
              }
            } catch (_) {}
          }
        }
      }

      if (targetConfigFile == null) {
        throw Exception('解压成功但在包内未检索到有效的 config.json');
      }

      final jsonContent = await targetConfigFile.readAsString();
      final configMap = cleanAndParseJson(jsonContent);

      final fileUri = toFileUri(targetConfigFile.path);

      return ConfigLoadResult(
        configMap: configMap,
        effectiveBaseUrl: fileUri,
        localPackageDir: targetConfigFile.parent.path,
        type: ConfigType.localPackage,
        suggestedName: '本地包: $rawName',
      );
    } catch (e) {
      print('解压或解析本地包失败: $e');
      rethrow;
    }
  }


  /// 加载网络/局域网远程点播配置 (自动跟随重定向并推导真实 baseUrl)
  Future<ConfigLoadResult?> loadOnlineConfig(String onlineUrl) async {
    try {
      print('🌐 正在请求远程点播配置: $onlineUrl');
      final response = await _dio.get<String>(
        onlineUrl,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final body = response.data ?? '';
      if (body.isEmpty) throw Exception('服务器返回配置内容为空');

      final realUrl = response.realUri.toString();
      final configMap = cleanAndParseJson(body);

      String suggestedName = '远程配置';
      try {
        final uri = Uri.parse(realUrl);
        suggestedName = '远程: ${uri.host}${uri.pathSegments.isNotEmpty ? '/${uri.pathSegments.last}' : ''}';
      } catch (_) {}

      return ConfigLoadResult(
        configMap: configMap,
        effectiveBaseUrl: realUrl,
        localPackageDir: null,
        type: ConfigType.remote,
        suggestedName: suggestedName,
      );
    } catch (e) {
      print('加载网络配置失败 ($onlineUrl): $e');
      return null;
    }
  }

  /// 获取原始文本内容 (支持 HTTP、clan:// 与 本地磁盘绝对路径)
  Future<String> loadRaw(
    String urlOrPath, {
    String? localPackageDir,
    String? baseUrl,
  }) async {
    final clean = urlOrPath.trim();

    // 1. 处理 clan://localhost/ 协议
    if (clean.startsWith('clan://localhost/')) {
      final rel = clean.replaceFirst('clan://localhost/', '');
      final candidateDirs = [
        if (localPackageDir != null) localPackageDir,
        'D:/code/ok影视js源/my/src',
        'D:/code/ok影视js源/my',
        if (baseUrl != null && !baseUrl.startsWith('http')) File(fromFileUri(baseUrl)).parent.path,
      ];

      for (final dir in candidateDirs) {
        final f = File('$dir/$rel');
        if (await f.exists()) {
          return await f.readAsString();
        }
      }
    }

    // 2. 处理 HTTP/HTTPS
    if (clean.startsWith('http://') || clean.startsWith('https://')) {
      try {
        final res = await _dio.get<String>(
          clean,
          options: Options(responseType: ResponseType.plain),
        );
        return res.data ?? '';
      } catch (e) {
        print('loadRaw 远程拉取失败: $clean ($e)');
        return '';
      }
    }

    // 3. 处理 file:// 协议与绝对路径
    final fsPath = fromFileUri(clean);
    final f = File(fsPath);
    if (await f.exists()) {
      return await f.readAsString();
    }

    return '';
  }

  /// 容错 JSON 解析器：自动剔除注释、多余尾随逗号、BOM 头与 Base64 外壳
  Map<String, dynamic> cleanAndParseJson(String raw) {
    if (raw.isEmpty) return {};
    String text = raw.trim();

    // 1. 过滤 UTF-8 BOM
    if (text.startsWith('\uFEFF')) {
      text = text.substring(1).trim();
    }

    // 2. 检查是否为整体 Base64 编码 (常见于 TVBox / OK影视加密源)
    if (!text.startsWith('{') && !text.startsWith('[')) {
      try {
        final decodedBytes = base64.decode(text.replaceAll(RegExp(r'\s+'), ''));
        final decodedStr = utf8.decode(decodedBytes).trim();
        if (decodedStr.startsWith('{') || decodedStr.startsWith('[')) {
          text = decodedStr;
        }
      } catch (_) {}
    }

    // 3. 去除单行注释 // 与 多行注释 /* */
    text = _stripJsonComments(text);

    // 4. 去除对象或数组尾部多余的逗号
    text = text.replaceAll(RegExp(r',\s*([\]}])'), r'$1');

    // 5. 标准 jsonDecode
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      } else if (decoded is List) {
        return {'sites': decoded};
      }
    } catch (e) {
      print('cleanAndParseJson 标准解码失败: $e');
    }

    return {};
  }

  static String _stripJsonComments(String input) {
    final sb = StringBuffer();
    bool inString = false;
    bool inSingleComment = false;
    bool inMultiComment = false;
    String stringChar = '';

    for (int i = 0; i < input.length; i++) {
      final c = input[i];
      final next = (i + 1 < input.length) ? input[i + 1] : '';

      if (inSingleComment) {
        if (c == '\n' || c == '\r') {
          inSingleComment = false;
          sb.write(c);
        }
        continue;
      }

      if (inMultiComment) {
        if (c == '*' && next == '/') {
          inMultiComment = false;
          i++; // 跳过 '/'
        }
        continue;
      }

      if (inString) {
        sb.write(c);
        if (c == '\\' && i + 1 < input.length) {
          i++;
          sb.write(input[i]);
        } else if (c == stringChar) {
          inString = false;
        }
        continue;
      }

      if (c == '"' || c == "'") {
        inString = true;
        stringChar = c;
        sb.write(c);
        continue;
      }

      if (c == '/' && next == '/') {
        inSingleComment = true;
        i++;
        continue;
      }

      if (c == '/' && next == '*') {
        inMultiComment = true;
        i++;
        continue;
      }

      sb.write(c);
    }

    return sb.toString();
  }

  Future<Directory> _getPackagesBaseDirectory() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final dir = Directory('${appDir.path}/ftv_packages');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      final temp = Directory.systemTemp;
      final dir = Directory('${temp.path}/ftv_packages');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
  }

  Future<File> _getHistoryFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}/$_historyFileName');
    } catch (_) {
      return File('${Directory.systemTemp.path}/$_historyFileName');
    }
  }

  Future<List<ConfigItemModel>> getHistory() async {
    try {
      final file = await _getHistoryFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = jsonDecode(content) as List;
        return list.map((e) => ConfigItemModel.fromJson(Map<String, dynamic>.from(e))).toList();
      }
    } catch (e) {
      print('读取历史配置异常: $e');
    }
    return [];
  }

  Future<void> saveHistory(List<ConfigItemModel> history) async {
    try {
      final file = await _getHistoryFile();
      final jsonStr = jsonEncode(history.map((e) => e.toJson()).toList());
      await file.writeAsString(jsonStr);
    } catch (e) {
      print('保存配置历史失败: $e');
    }
  }

  Future<void> recordActiveConfig(ConfigItemModel item) async {
    try {
      final list = await getHistory();
      final existingIdx = list.indexWhere((e) => e.id == item.id || e.urlOrPath == item.urlOrPath);

      if (existingIdx != -1) {
        list.removeAt(existingIdx);
      }

      for (var it in list) {
        it.isActive = false;
      }

      item.isActive = true;
      item.lastUsed = DateTime.now();
      list.insert(0, item);

      if (list.length > 20) {
        list.removeRange(20, list.length);
      }

      await saveHistory(list);
    } catch (e) {
      print('记录激活配置失败: $e');
    }
  }

  Future<ConfigItemModel?> getActiveConfig() async {
    final list = await getHistory();
    if (list.isEmpty) return null;
    return list.firstWhere((e) => e.isActive, orElse: () => list.first);
  }

  /// 获取原始在线/网络文本配置 (兼容调试视图 source_test_view 调用)
  Future<String> loadOnlineConfigRaw(String onlineUrl) => loadRaw(onlineUrl);

  /// 读取配置历史列表 (兼容 loadHistory 与 getHistory)
  Future<List<ConfigItemModel>> loadHistory() => getHistory();

  /// 删除单条配置历史记录 (别名兼容)
  Future<void> removeHistory(String id) => removeHistoryItem(id);

  /// 删除单条配置历史记录
  Future<void> removeHistoryItem(String id) async {
    try {
      final list = await getHistory();
      list.removeWhere((e) => e.id == id || e.urlOrPath == id);
      await saveHistory(list);
    } catch (e) {
      print('删除历史配置项失败: $e');
    }
  }

  /// 清空所有历史配置记录
  Future<void> clearHistory() async {
    try {
      await saveHistory([]);
    } catch (e) {
      print('清空历史配置失败: $e');
    }
  }
}
