import 'package:flutter/material.dart';
import '../../../models/vod_model.dart';
import '../../widgets/tv_focusable.dart';

/// 搜索结果单项卡片 (带左上角橙红站源 Badge、底部状态、居中标题)
class SearchResultCard extends StatelessWidget {
  final VodItem vod;
  final VoidCallback onTap;

  const SearchResultCard({
    super.key,
    required this.vod,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final remarks = vod.vodRemarks.isNotEmpty ? vod.vodRemarks : '4K';
    final site = vod.siteName ?? '默认源';

    return TvFocusable(
      onPressed: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF2E6359),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.18),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  vod.vodPic.isNotEmpty
                      ? Image.network(
                          vod.vodPic,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              Container(
                            color: const Color(0xFF264841),
                            child: Icon(
                              vod.isFolder ? Icons.folder : Icons.movie,
                              size: 36,
                              color: Colors.white54,
                            ),
                          ),
                        )
                      : Container(
                          color: const Color(0xFF264841),
                          child: Icon(
                            vod.isFolder ? Icons.folder : Icons.movie,
                            size: 36,
                            color: Colors.white54,
                          ),
                        ),

                  // 左上角橙红色站源 Badge
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE64A19),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        site,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),

                  // 底部清晰度 / 更新集数状态条
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      color: Colors.black.withOpacity(0.55),
                      child: Text(
                        remarks,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 10),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 卡片底部居中标题
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              alignment: Alignment.center,
              child: Text(
                vod.vodName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
