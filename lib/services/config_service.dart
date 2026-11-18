import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import '../models/config_model.dart';

/// OK影视 / FongMi 原生点播配置服务
/// 深度支持：
/// 1. Android SAF 文件选择器 (支持 content:// 无实体路径读取、cache 自动持久化、FileType.any 规避 MIME 过滤问题)
/// 2. Windows / 桌面端硬盘文件 (.json / .zip / .txt) 与硬盘文件夹直选
/// 3. 本地目录与离线 ZIP 包自动解压索引 (以内部 config.json 为基准推导全部 js/lib/config 相对路径)
/// 4. 远程 HTTP/HTTPS 配置 (自动跟随重定向并推导 baseUrl)
/// 5. clan://localhost/ 虚拟协议本地映射
/// 6. 增强容错 JSON 解析 (UTF-8/UTF-16 BOM、注释、尾随逗号、单引号 JSON5、Base64 与 ** 图片隐藏编码)
class ConfigService {
  late final Dio _dio;
  static const String _historyFileName = 'ftv_config_history.json';
  static const MethodChannel _storageChannel = MethodChannel('com.example.ftv/storage');

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
  // 1. 本地文件与文件夹选择器 (Android SAF + Windows 硬盘文件)
  // ─────────────────────────────────────────────────────────────────────────────

  /// 调用系统选择器导入本地包 (.zip) 或配置文件 (.json / .txt)
  /// Android 端使用 FileType.any 避免部分国产 ROM / 电视文件管理器将 .json 置灰无法选择
  Future<ConfigLoadResult?> pickAndLoadConfig() async {
    try {
      if (Platform.isAndroid) {
        final picked = await _storageChannel.invokeMapMethod<String, dynamic>('pickConfigFile');
        if (picked == null) return null;
        final name = (picked['name'] as String?) ?? 'config.json';
        final realPath = picked['path'] as String?;
        final rawBytes = picked['bytes'];
        final List<int>? bytes = rawBytes is List<int>
            ? rawBytes
            : (rawBytes is List ? rawBytes.cast<int>() : null);
        return await _loadConfigFromNamePathBytes(
          fileName: name,
          diskPath: realPath,
          bytes: bytes,
        );
      }

      final PlatformFile? file = await FilePicker.pickFile(
        dialogTitle: '选择本地配置文件 (.json / .zip / .txt)',
        type: FileType.custom,
        allowedExtensions: ['json', 'zip', 'txt', 'json5', 'conf'],
      );

      if (file == null) return null;
      return await loadConfigFromPickedFile(file);
    } catch (e) {
      print('文件选择或读取失败: $e');
      rethrow;
    }
  }

  /// 调用系统文件夹选择器导入本地硬盘配置目录 (Windows / Android 均适用)
  Future<bool> hasAndroidAllFilesAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _storageChannel.invokeMethod<bool>('hasAllFilesAccess');
      return res ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> requestAndroidAllFilesAccess() async {
    if (!Platform.isAndroid) return;
    try {
      await _storageChannel.invokeMethod('requestAllFilesAccess');
    } catch (_) {}
  }

  /// 将 Android SAF content:// identifier 解析为真实的 /storage/emulated/0/... 路径
  static String? resolveAndroidRealPath(String? identifier, String? rawPath) {
    if (rawPath != null &&
        rawPath.isNotEmpty &&
        !rawPath.contains('/cache/') &&
        rawPath.startsWith('/storage/')) {
      return rawPath;
    }
    if (identifier == null || identifier.isEmpty) return null;

    try {
      final decoded = Uri.decodeFull(identifier);
      // 1. content://com.android.externalstorage.documents/document/primary:Download/xxx
      final primaryMatch = RegExp(r'primary:(.+)$').firstMatch(decoded);
      if (primaryMatch != null) {
        final rel = primaryMatch.group(1)!.replaceAll(RegExp(r'^/+'), '');
        return '/storage/emulated/0/$rel';
      }
      // 2. raw:/storage/emulated/0/...
      final rawMatch = RegExp(r'(/storage/[^?#]+)').firstMatch(decoded);
      if (rawMatch != null) {
        return rawMatch.group(1)!;
      }
    } catch (_) {}
    return null;
  }

  Future<ConfigLoadResult?> pickAndLoadDirectory() async {
    try {
      if (Platform.isAndroid && !await hasAndroidAllFilesAccess()) {
        await requestAndroidAllFilesAccess();
        throw Exception('请在系统设置中授予“所有文件访问权限”，返回后再选择文件夹');
      }
      final dirPath = await FilePicker.getDirectoryPath(
        dialogTitle: '选择本地配置文件夹',
      );
      if (dirPath == null || dirPath.trim().isEmpty) return null;
      final resolved = resolveAndroidRealPath(dirPath, dirPath) ?? dirPath.trim();
      return await loadFromDirectory(resolved);
    } catch (e) {
      print('文件夹选择或读取失败: $e');
      rethrow;
    }
  }

  /// 从 FilePicker 返回的 PlatformFile 加载配置
  /// 兼容：
  /// - Windows/macOS/Linux 真实硬盘路径 (保留原目录，确保 ./js/、clan:// 相对路径可用)
  /// - Android SAF 无实体路径 (path == null) 或临时缓存路径 (/cache/file_picker/) -> 自动持久化到应用私有目录
  Future<ConfigLoadResult?> loadConfigFromPickedFile(PlatformFile pickedFile) async {
    final fileName = pickedFile.name.isNotEmpty ? pickedFile.name : 'config.json';
    final rawPath = pickedFile.path;

    List<int>? bytes;
    if (rawPath != null && rawPath.isNotEmpty) {
      final diskFile = File(rawPath);
      if (await diskFile.exists()) {
        bytes = await diskFile.readAsBytes();
      }
    }
    bytes ??= await pickedFile.readAsBytes();

    final validDiskPath = (rawPath != null &&
            rawPath.isNotEmpty &&
            !rawPath.contains('/cache/') &&
            !rawPath.contains('\\cache\\'))
        ? rawPath
        : null;

    return await _loadConfigFromNamePathBytes(
      fileName: fileName,
      diskPath: validDiskPath,
      bytes: bytes,
    );
  }

  Future<ConfigLoadResult?> _loadConfigFromNamePathBytes({
    required String fileName,
    String? diskPath,
    List<int>? bytes,
  }) async {
    final lowerName = fileName.toLowerCase();

    if ((bytes == null || bytes.isEmpty) && diskPath != null && diskPath.isNotEmpty) {
      final f = File(diskPath);
      if (await f.exists()) {
        bytes = await f.readAsBytes();
      }
    }

    if (bytes == null || bytes.isEmpty) {
      throw Exception('所选文件内容为空: $fileName');
    }

    // 判断是否为 ZIP 压缩包 (扩展名或 PK 魔数 0x50 0x4B)
    final isZip = lowerName.endsWith('.zip') ||
        (bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B);

    if (isZip) {
      return await extractAndLoadZipBytes(bytes, fileName);
    }

    // 桌面端或 Android 真实外部存储路径 (/storage/emulated/0/...)：
    // 优先使用真实路径，确保同级 ./js/、./lib/、clan://localhost/ 相对路径可直接加载
    if (diskPath != null && diskPath.isNotEmpty) {
      if (Platform.isAndroid) {
        final hasAccess = await hasAndroidAllFilesAccess();
        if (!hasAccess) {
          throw Exception('未授予“所有文件访问权限”，请授权后重试');
        }
      }
      final diskFile = File(diskPath);
      if (await diskFile.exists()) {
        final content = decodeBytesToString(bytes);
        final configMap = cleanAndParseJson(content);
        if (configMap.isEmpty) {
          throw Exception('未能从 $fileName 解析出有效的配置结构');
        }
        return ConfigLoadResult(
          configMap: configMap,
          effectiveBaseUrl: toFileUri(diskFile.path),
          localPackageDir: diskFile.parent.path.replaceAll('\\', '/'),
          type: ConfigType.localFile,
          suggestedName: '本地配置: $fileName',
        );
      }
    }

    // 非外部存储真实路径时，持久化复制到应用支持目录
    final content = decodeBytesToString(bytes);
    final configMap = cleanAndParseJson(content);
    if (configMap.isEmpty) {
      throw Exception('未能从 $fileName 解析出有效的 JSON 配置');
    }

    final savedFile = await _saveConfigBytesToPersistentDir(bytes, fileName);
    return ConfigLoadResult(
      configMap: configMap,
      effectiveBaseUrl: toFileUri(savedFile.path),
      localPackageDir: savedFile.parent.path.replaceAll('\\', '/'),
      type: ConfigType.localFile,
      suggestedName: '本地配置: $fileName',
    );
  }

  /// 规范化本地绝对路径（直接使用原始绝对路径，不再拼接 file:// 前缀）
  static String toFileUri(String path) {
    String clean = path.trim().replaceAll('\\', '/');
    if (clean.startsWith('file://')) {
      return fromFileUri(clean);
    }
    return clean;
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
    return null;
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

  /// 从单文件配置加载（严格以文件自身所在目录为准，容错编码）
  Future<ConfigLoadResult?> loadLocalFileConfig(String filePath) async {
    try {
      final normalizedPath = filePath.replaceAll('\\', '/');
      final file = File(normalizedPath);
      if (!await file.exists()) {
        throw Exception('配置文件不存在: $normalizedPath');
      }

      final bytes = await file.readAsBytes();
      final content = decodeBytesToString(bytes);
      final configMap = cleanAndParseJson(content);
      if (configMap.isEmpty) {
        throw Exception('配置文件解析结果为空: $normalizedPath');
      }

      final parentDir = file.parent.path.replaceAll('\\', '/');
      final segments = normalizedPath.split('/').where((s) => s.isNotEmpty).toList();
      final fileName = segments.isNotEmpty ? segments.last : 'config.json';

      return ConfigLoadResult(
        configMap: configMap,
        effectiveBaseUrl: toFileUri(file.path),
        localPackageDir: parentDir,
        type: ConfigType.localFile,
        suggestedName: '本地配置: $fileName',
      );
    } catch (e) {
      print('加载本地配置文件失败: $e');
      return null;
    }
  }

  /// 从本地文件夹目录直接加载配置包 (如 D:/code/ok影视js源/my 或 Android 文件夹)
  Future<ConfigLoadResult?> loadFromDirectory(String dirPath) async {
    try {
      final normalizedDir = dirPath.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
      final dir = Directory(normalizedDir);
      if (!await dir.exists()) {
        throw Exception('指定目录不存在: $normalizedDir');
      }

      print('📂 正在探测本地目录源: $normalizedDir');

      final targetFile = await _findConfigFileInDirectory(dir);
      if (targetFile == null) {
        throw Exception('目录内未检索到有效的 config.json: $normalizedDir');
      }

      final bytes = await targetFile.readAsBytes();
      final content = decodeBytesToString(bytes);
      final configMap = cleanAndParseJson(content);
      if (configMap.isEmpty) {
        throw Exception('目录内配置文件解析失败: ${targetFile.path}');
      }

      final folderSegments = normalizedDir.split('/').where((s) => s.isNotEmpty).toList();
      final folderName = folderSegments.isNotEmpty ? folderSegments.last : 'local';
      final fileUri = toFileUri(targetFile.path);

      return ConfigLoadResult(
        configMap: configMap,
        effectiveBaseUrl: fileUri,
        localPackageDir: targetFile.parent.path.replaceAll('\\', '/'),
        type: ConfigType.localPackage,
        suggestedName: '本地源: $folderName',
      );
    } catch (e) {
      print('加载本地目录失败: $e');
      return null;
    }
  }

  /// 解压本地 ZIP 压缩包路径
  Future<ConfigLoadResult?> extractAndLoadZip(String zipFilePath) async {
    try {
      final normalizedPath = zipFilePath.replaceAll('\\', '/');
      final zipFile = File(normalizedPath);
      if (!await zipFile.exists()) {
        throw Exception('ZIP 文件不存在: $normalizedPath');
      }

      print('🚀 开始解压本地包: $normalizedPath');
      final bytes = await zipFile.readAsBytes();
      final segments = normalizedPath.split('/').where((s) => s.isNotEmpty).toList();
      final fileName = segments.isNotEmpty ? segments.last : 'package.zip';
      return await extractAndLoadZipBytes(bytes, fileName);
    } catch (e) {
      print('解压或解析本地包失败: $e');
      rethrow;
    }
  }

  /// 直接从字节流解压 ZIP 包并解析内部配置 (兼容 Android SAF 无实体路径)
  Future<ConfigLoadResult?> extractAndLoadZipBytes(List<int> bytes, String fileName) async {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);

      final baseDir = await _getPackagesBaseDirectory();
      final rawName = fileName.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '');
      final safeName = rawName.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5_-]'), '_');
      final folderSafeName = safeName.isNotEmpty
          ? safeName
          : 'package_${DateTime.now().millisecondsSinceEpoch}';
      final extractDir = Directory('${baseDir.path}/$folderSafeName');

      if (!await extractDir.exists()) {
        await extractDir.create(recursive: true);
      }

      // 将压缩包内全部文件安全解压至本地沙盒 (防御 Zip Slip 路径穿越)
      final extractRoot = extractDir.path.replaceAll('\\', '/');
      for (final file in archive) {
        final normalizedEntry = file.name.replaceAll('\\', '/');
        if (normalizedEntry.contains('..')) continue;
        final outPath = '$extractRoot/$normalizedEntry';
        if (file.isFile) {
          final outFile = File(outPath);
          await outFile.parent.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        } else {
          await Directory(outPath).create(recursive: true);
        }
      }

      print('✅ 本地包解压完成，目标目录: ${extractDir.path}');

      final targetConfigFile = await _findConfigFileInDirectory(extractDir);
      if (targetConfigFile == null) {
        throw Exception('解压成功但在包内未检索到有效的配置文件');
      }

      final jsonBytes = await targetConfigFile.readAsBytes();
      final jsonContent = decodeBytesToString(jsonBytes);
      final configMap = cleanAndParseJson(jsonContent);
      if (configMap.isEmpty) {
        throw Exception('包内配置文件解析为空: ${targetConfigFile.path}');
      }

      final fileUri = toFileUri(targetConfigFile.path);

      return ConfigLoadResult(
        configMap: configMap,
        effectiveBaseUrl: fileUri,
        localPackageDir: targetConfigFile.parent.path.replaceAll('\\', '/'),
        type: ConfigType.localPackage,
        suggestedName: '本地包: $rawName',
      );
    } catch (e) {
      print('解压或解析本地包失败: $e');
      rethrow;
    }
  }

  /// 在目录内智能定位配置文件 (支持常见路径 + 加密/Base64 配置探测)
  Future<File?> _findConfigFileInDirectory(Directory dir) async {
    final rootPath = dir.path.replaceAll('\\', '/');
    final candidates = [
      '$rootPath/config.json',
      '$rootPath/src/config.json',
      '$rootPath/dist/config.json',
      '$rootPath/config/config.json',
      '$rootPath/tvbox.json',
      '$rootPath/api.json',
    ];

    for (final p in candidates) {
      final f = File(p);
      if (await f.exists()) {
        return f;
      }
    }

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final lower = entity.path.toLowerCase();
        if (lower.endsWith('.json') || lower.endsWith('.txt') || lower.endsWith('.json5')) {
          try {
            final bytes = await entity.readAsBytes();
            final content = decodeBytesToString(bytes);
            if (content.contains('"sites"') ||
                content.contains("'sites'") ||
                content.contains('"lives"')) {
              print('🔍 全盘搜寻匹配到配置文件: ${entity.path}');
              return entity;
            }
            // 兼容 Base64 编码或加密外壳的配置文件
            final parsed = cleanAndParseJson(content);
            if (parsed.containsKey('sites') ||
                parsed.containsKey('lives') ||
                parsed.containsKey('spider')) {
              print('🔍 解析探测匹配到配置文件: ${entity.path}');
              return entity;
            }
          } catch (_) {}
        }
      }
    }
    return null;
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
        suggestedName =
            '远程: ${uri.host}${uri.pathSegments.isNotEmpty ? '/${uri.pathSegments.last}' : ''}';
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
      final baseParent = (baseUrl != null && !baseUrl.startsWith('http'))
          ? File(fromFileUri(baseUrl)).parent.path.replaceAll('\\', '/')
          : null;
      final baseGrandParent = (baseUrl != null && !baseUrl.startsWith('http'))
          ? File(fromFileUri(baseUrl)).parent.parent.path.replaceAll('\\', '/')
          : null;

      final candidateDirs = [
        if (localPackageDir != null) localPackageDir.replaceAll('\\', '/'),
        if (baseParent != null) baseParent,
        if (baseGrandParent != null) baseGrandParent,
      ];

      for (final dir in candidateDirs) {
        final f = File('$dir/$rel');
        if (await f.exists()) {
          return decodeBytesToString(await f.readAsBytes());
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
      return decodeBytesToString(await f.readAsBytes());
    }

    return '';
  }

  /// 编码容错解码：支持 UTF-8 BOM、UTF-16 LE/BE BOM 及非严格 UTF-8 字节流
  static String decodeBytesToString(List<int> bytes) {
    if (bytes.isEmpty) return '';

    // UTF-8 BOM: EF BB BF
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }

    // UTF-16 LE BOM: FF FE
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      final codeUnits = <int>[];
      for (int i = 2; i + 1 < bytes.length; i += 2) {
        codeUnits.add(bytes[i] | (bytes[i + 1] << 8));
      }
      return String.fromCharCodes(codeUnits);
    }

    // UTF-16 BE BOM: FE FF
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      final codeUnits = <int>[];
      for (int i = 2; i + 1 < bytes.length; i += 2) {
        codeUnits.add((bytes[i] << 8) | bytes[i + 1]);
      }
      return String.fromCharCodes(codeUnits);
    }

    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 增强容错 JSON 解析器：
  /// 支持 UTF-8 BOM、Base64 / ** 图片隐藏编码、// 和 /* */ 注释、尾随逗号、单引号 JSON5、控制字符转义
  Map<String, dynamic> cleanAndParseJson(String raw) {
    if (raw.isEmpty) return {};
    String text = raw.trim();

    // 1. 过滤 UTF-8 BOM
    if (text.startsWith('\uFEFF')) {
      text = text.substring(1).trim();
    }

    // 2. 检查是否为 TVBox / OK影视 Base64 编码或 ** 图片隐藏配置
    if (!text.startsWith('{') && !text.startsWith('[')) {
      // 2a. 处理 **<base64> 伪装格式
      if (text.contains('**')) {
        final idx = text.lastIndexOf('**');
        final candidate = text.substring(idx + 2).trim();
        final decoded = _tryDecodeBase64Config(candidate);
        if (decoded != null) text = decoded;
      }
      // 2b. 处理整体 Base64 编码
      if (!text.startsWith('{') && !text.startsWith('[')) {
        final decoded = _tryDecodeBase64Config(text);
        if (decoded != null) text = decoded;
      }
    }

    // 3. 去除单行注释 // 与 多行注释 /* */
    text = _stripJsonComments(text).trim();

    // 4. 去除对象或数组尾部多余的逗号
    text = text.replaceAll(RegExp(r',\s*([\]}])'), r'$1');

    // 5. 首次尝试标准 jsonDecode
    final firstTry = _tryJsonDecodeToMap(text);
    if (firstTry != null) return firstTry;

    // 6. 提取最外层 {...} 或 [...] 区块（规避前后杂散字符或 JSONP 包装）
    final extracted = _extractOutermostJsonBlock(text);
    if (extracted != null && extracted != text) {
      final secondTry = _tryJsonDecodeToMap(extracted);
      if (secondTry != null) return secondTry;
      text = extracted;
    }

    // 7. 容错修复：单引号 JSON5 与未转义控制字符
    final normalized = _normalizeRelaxedJson(text)
        .replaceAll(RegExp(r',\s*([\]}])'), r'$1');
    final thirdTry = _tryJsonDecodeToMap(normalized);
    if (thirdTry != null) return thirdTry;

    print('cleanAndParseJson 全部容错解码均失败');
    return {};
  }

  static Map<String, dynamic>? _tryJsonDecodeToMap(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      } else if (decoded is List) {
        return {'sites': decoded};
      }
    } catch (_) {}
    return null;
  }

  static String? _tryDecodeBase64Config(String raw) {
    try {
      String cleaned = raw.replaceAll(RegExp(r'\s+'), '');
      if (cleaned.isEmpty) return null;
      // 兼容 URL-Safe Base64
      cleaned = cleaned.replaceAll('-', '+').replaceAll('_', '/');
      final mod = cleaned.length % 4;
      if (mod != 0) {
        cleaned = cleaned.padRight(cleaned.length + (4 - mod), '=');
      }
      final decodedBytes = base64.decode(cleaned);
      final decodedStr = decodeBytesToString(decodedBytes).trim();
      if (decodedStr.startsWith('{') || decodedStr.startsWith('[')) {
        return decodedStr;
      }
    } catch (_) {}
    return null;
  }

  static String? _extractOutermostJsonBlock(String text) {
    final objStart = text.indexOf('{');
    final arrStart = text.indexOf('[');
    int start = -1;
    String openChar = '{';
    String closeChar = '}';

    if (objStart != -1 && (arrStart == -1 || objStart < arrStart)) {
      start = objStart;
      openChar = '{';
      closeChar = '}';
    } else if (arrStart != -1) {
      start = arrStart;
      openChar = '[';
      closeChar = ']';
    }
    if (start == -1) return null;

    final end = text.lastIndexOf(closeChar);
    if (end <= start) return null;
    final sub = text.substring(start, end + 1);
    if (!sub.startsWith(openChar)) return null;
    return sub;
  }

  /// 将单引号字符串 / 未转义换行制表符规范化为标准 JSON
  static String _normalizeRelaxedJson(String input) {
    final sb = StringBuffer();
    bool inDoubleQuote = false;
    bool inSingleQuote = false;

    for (int i = 0; i < input.length; i++) {
      final c = input[i];

      if (inDoubleQuote) {
        if (c == '\\' && i + 1 < input.length) {
          sb.write(c);
          sb.write(input[++i]);
        } else if (c == '"') {
          inDoubleQuote = false;
          sb.write(c);
        } else if (c == '\n') {
          sb.write(r'\n');
        } else if (c == '\r') {
          sb.write(r'\r');
        } else if (c == '\t') {
          sb.write(r'\t');
        } else {
          sb.write(c);
        }
        continue;
      }

      if (inSingleQuote) {
        if (c == '\\' && i + 1 < input.length) {
          final next = input[++i];
          if (next == "'") {
            sb.write("'");
          } else {
            sb.write('\\');
            sb.write(next);
          }
        } else if (c == "'") {
          inSingleQuote = false;
          sb.write('"');
        } else if (c == '"') {
          sb.write(r'\"');
        } else if (c == '\n') {
          sb.write(r'\n');
        } else if (c == '\r') {
          sb.write(r'\r');
        } else if (c == '\t') {
          sb.write(r'\t');
        } else {
          sb.write(c);
        }
        continue;
      }

      if (c == '"') {
        inDoubleQuote = true;
        sb.write(c);
      } else if (c == "'") {
        inSingleQuote = true;
        sb.write('"');
      } else {
        sb.write(c);
      }
    }
    return sb.toString();
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
          i++;
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

  Future<File> _saveConfigBytesToPersistentDir(List<int> bytes, String fileName) async {
    final dir = await _getConfigsBaseDirectory();
    final safeName = fileName.replaceAll(RegExp(r'[^\w.\u4e00-\u9fa5_-]'), '_');
    final finalName = safeName.isNotEmpty ? safeName : 'config.json';
    final outFile = File('${dir.path}/$finalName');
    await outFile.writeAsBytes(bytes, flush: true);
    return outFile;
  }

  Future<Directory> _getConfigsBaseDirectory() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final dir = Directory('${appDir.path}/ftv_configs');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      final temp = Directory.systemTemp;
      final dir = Directory('${temp.path}/ftv_configs');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
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
