import 'package:flutter/material.dart';
import '../../services/theme_service.dart';

/// 个性设置子页 (严格复刻参考图 5)
class PersonalSettingsPage extends StatefulWidget {
  final ThemeService themeService;

  const PersonalSettingsPage({super.key, required this.themeService});

  @override
  State<PersonalSettingsPage> createState() => _PersonalSettingsPageState();
}

class _PersonalSettingsPageState extends State<PersonalSettingsPage> {
  String picSize = '大';
  String playRate = '1.00';
  String longPressRate = '3.00';
  String incognito = '关闭';
  String multiSearch = '关闭';
  String showSource = '开启';
  String sourceSearch = '开启';
  String aiAdBlock = '开启';
  String localDownload = '关闭';
  String lang = '简体中文';
  String debugMode = '开启';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(gradient: widget.themeService.currentGradient),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 8),
                    const Text('个性设置', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  children: [
                    _buildItem('图片尺寸', picSize, () => setState(() => picSize = picSize == '大' ? '中' : '大')),
                    _buildItem('播放倍速', playRate, () => setState(() => playRate = playRate == '1.00' ? '1.25' : '1.00')),
                    _buildItem('长按倍速', longPressRate, () => setState(() => longPressRate = longPressRate == '3.00' ? '2.00' : '3.00')),
                    _buildItem('无痕模式', incognito, () => setState(() => incognito = incognito == '关闭' ? '开启' : '关闭')),
                    _buildItem('聚合搜索', multiSearch, () => setState(() => multiSearch = multiSearch == '关闭' ? '开启' : '关闭')),
                    _buildItem('显示站源', showSource, () => setState(() => showSource = showSource == '开启' ? '关闭' : '开启')),
                    _buildItem('站源搜索', sourceSearch, () => setState(() => sourceSearch = sourceSearch == '开启' ? '关闭' : '开启')),
                    _buildItem('AI去广告', aiAdBlock, () => setState(() => aiAdBlock = aiAdBlock == '开启' ? '关闭' : '开启')),
                    _buildItem('内置下载', localDownload, () => setState(() => localDownload = localDownload == '关闭' ? '开启' : '关闭')),
                    _buildItem('语言设置', lang, () {}),
                    _buildItem('调试模式', debugMode, () => setState(() => debugMode = debugMode == '开启' ? '关闭' : '开启')),
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: const Color(0x66336B61),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        onTap: () {},
                        title: const Text('重置App', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItem(String title, String val, VoidCallback onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0x66336B61),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        onTap: onTap,
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
        trailing: Text(val, style: const TextStyle(color: Colors.white, fontSize: 15)),
      ),
    );
  }
}

