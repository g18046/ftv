import 'package:flutter/material.dart';

/// 搜索初始态：历史搜索与搜索建议热词胶囊
class SearchSuggestionsView extends StatelessWidget {
  final List<String> historyKeywords;
  final List<String> suggestKeywords;
  final ValueChanged<String> onTapKeyword;
  final VoidCallback onClearHistory;

  const SearchSuggestionsView({
    super.key,
    required this.historyKeywords,
    required this.suggestKeywords,
    required this.onTapKeyword,
    required this.onClearHistory,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      children: [
        if (historyKeywords.isNotEmpty) ...[
          Row(
            children: [
              const Text(
                '历史',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: Colors.white60, size: 20),
                tooltip: '清空历史',
                onPressed: onClearHistory,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: historyKeywords.map((kw) {
              return InkWell(
                onTap: () => onTapKeyword(kw),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0x33FFFFFF),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    kw,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 24),
        ],
        const Text(
          '建议',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: suggestKeywords.map((kw) {
            return InkWell(
              onTap: () => onTapKeyword(kw),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0x33FFFFFF),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  kw,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
