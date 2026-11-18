/// 应用版本号与更新说明集中管理
class AppVersion {
  static const String version = '1.0.0';

  static const List<Map<String, dynamic>> changelog = [
    {
      'version': '1.0.0',
      'date': '2026-11-17',
      'notes': [
        '支持本地 JS 源包导入、目录相对路径解析与 QuickJS 独立运行引擎',
        '支持点播卡片 style（list / rect / oval）、尺寸比例 ratio 与 land/circle 自适应',
        '支持 MPV / EXO 双播放核心切换、Windows 外调播放器（PotPlayer / VLC / 自定义）与局域网代理流',
        '支持夸克/光鸭网盘预览图、115/夸克/光鸭网盘目录及多层嵌套 Back 手势返回',
        '支持实时弹幕匹配、推送字幕/弹幕 action、内置分集批量下载与双 Tab 下载管理',
        '支持网页调试日志（/logs）与全屏独立日志页（支持正则过滤与跨行全选）',
        '支持 Windows 系统代理自动适配与全屏播放自动隐藏顶部标题栏',
      ],
    },
  ];
}
