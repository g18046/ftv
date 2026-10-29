/// 配置类型枚举
enum ConfigType {
  remote, // 远程 HTTP(S) 网络点播配置
  localPackage, // 本地 ZIP 压缩包 (已解压沙盒包)
  localFile, // 本地单个 JSON 配置文件
  builtin, // 项目内置测试源
}

/// 点播配置记录模型 (支持历史多源切换、持久化、状态标识)
class ConfigItemModel {
  final String id;
  String name;
  String urlOrPath;
  ConfigType type;
  DateTime lastUsed;
  int siteCount;
  bool isActive;
  String? localPackageDir; // 解压后的本地包根目录 (用于 clan://localhost/ 虚拟协议映射)

  ConfigItemModel({
    required this.id,
    required this.name,
    required this.urlOrPath,
    required this.type,
    required this.lastUsed,
    this.siteCount = 0,
    this.isActive = false,
    this.localPackageDir,
  });

  factory ConfigItemModel.fromJson(Map<String, dynamic> json) {
    ConfigType parseType(String? t) {
      switch (t) {
        case 'localPackage':
          return ConfigType.localPackage;
        case 'localFile':
          return ConfigType.localFile;
        case 'builtin':
          return ConfigType.builtin;
        case 'remote':
        default:
          return ConfigType.remote;
      }
    }

    return ConfigItemModel(
      id: json['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: json['name']?.toString() ?? '未命名配置源',
      urlOrPath: json['urlOrPath']?.toString() ?? '',
      type: parseType(json['type']?.toString()),
      lastUsed: json['lastUsed'] != null
          ? DateTime.tryParse(json['lastUsed'].toString()) ?? DateTime.now()
          : DateTime.now(),
      siteCount: json['siteCount'] is int
          ? json['siteCount']
          : int.tryParse(json['siteCount']?.toString() ?? '0') ?? 0,
      isActive: json['isActive'] == true,
      localPackageDir: json['localPackageDir']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'urlOrPath': urlOrPath,
      'type': type.name,
      'lastUsed': lastUsed.toIso8601String(),
      'siteCount': siteCount,
      'isActive': isActive,
      'localPackageDir': localPackageDir,
    };
  }

  String get typeLabel {
    switch (type) {
      case ConfigType.localPackage:
        return '本地包';
      case ConfigType.localFile:
        return '本地文件';
      case ConfigType.builtin:
        return '内置测试源';
      case ConfigType.remote:
      default:
        return '远程网络';
    }
  }
}

/// 配置加载结果封装
class ConfigLoadResult {
  final Map<String, dynamic> configMap;
  final String effectiveBaseUrl;
  final String? localPackageDir;
  final ConfigType type;
  final String suggestedName;

  ConfigLoadResult({
    required this.configMap,
    required this.effectiveBaseUrl,
    this.localPackageDir,
    required this.type,
    required this.suggestedName,
  });
}
