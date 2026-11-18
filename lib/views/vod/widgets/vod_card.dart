import 'package:flutter/material.dart';
import '../../../models/vod_model.dart';
import '../../widgets/tv_focusable.dart';

/// OK影视风格点播卡片
class VodCard extends StatelessWidget {
  final VodItem vod;
  final VoidCallback onTap;
  final String? styleType;

  const VodCard({
    super.key,
    required this.vod,
    required this.onTap,
    this.styleType,
  });

  @override
  Widget build(BuildContext context) {
    final year = vod.vodYear.isNotEmpty
        ? vod.vodYear
        : RegExp(r'20\d{2}').firstMatch(vod.vodRemarks)?.group(0) ?? '';
    final remarks = vod.vodRemarks;

    return TvFocusable(
      onPressed: onTap,
      child: Container(
        decoration: BoxDecoration(
          color:
              vod.isFolder ? const Color(0xFF234C43) : const Color(0xFF2E6359),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: vod.isFolder
                ? const Color(0xFFE5A00D).withValues(alpha: 0.4)
                : Colors.transparent,
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
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
                  (vod.style?['type']?.toString() ?? styleType) == 'oval'
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: AspectRatio(
                              aspectRatio: 1.0,
                              child: ClipOval(
                                child: vod.vodPic.isNotEmpty
                                    ? Image.network(
                                        vod.vodPic,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Container(
                                          color: const Color(0xFF264841),
                                          child: Icon(
                                            vod.isFolder ? Icons.folder_copy : Icons.movie,
                                            size: 36,
                                            color: const Color(0xFFE5A00D),
                                          ),
                                        ),
                                      )
                                    : Container(
                                        color: const Color(0xFF264841),
                                        child: Icon(
                                          vod.isFolder ? Icons.folder_copy : Icons.movie,
                                          size: 36,
                                          color: const Color(0xFFE5A00D),
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        )
                      : vod.vodPic.isNotEmpty
                      ? Image.network(
                          vod.vodPic,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              Container(
                            color: vod.isFolder
                                ? const Color(0xFF1E3D36)
                                : const Color(0xFF264841),
                            child: Icon(
                                vod.isFolder ? Icons.folder_copy : Icons.movie,
                                size: 40,
                                color: const Color(0xFFE5A00D)),
                          ),
                        )
                      : Container(
                          color: vod.isFolder
                              ? const Color(0xFF1E3D36)
                              : const Color(0xFF264841),
                          child: Icon(
                              vod.isFolder ? Icons.folder_copy : Icons.movie,
                              size: 40,
                              color: const Color(0xFFE5A00D)),
                        ),

                  // 左上角角标 (文件夹 or 年份；无年份时不显示背景)
                  if (vod.isFolder || (year.trim().isNotEmpty && year.trim() != '0' && year.trim().toLowerCase() != 'null'))
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: vod.isFolder
                            ? const Color(0xFFE5A00D)
                            : const Color(0xFF1E88E5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        vod.isFolder ? '文件夹' : year,
                        style: TextStyle(
                          color: vod.isFolder ? Colors.black : Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),

                  // 底部 Remarks Badge (无内容时不显示背景)
                  if (remarks.trim().isNotEmpty)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      color: Colors.black.withValues(alpha: 0.55),
                      child: Text(
                        remarks,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: vod.isFolder
                              ? const Color(0xFFE5A00D)
                              : Colors.white,
                          fontSize: 10,
                          fontWeight: vod.isFolder
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 卡片下部标题容器
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              alignment: Alignment.center,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (vod.isFolder)
                    const Padding(
                      padding: EdgeInsets.only(right: 4.0),
                      child: Icon(Icons.folder,
                          size: 14, color: Color(0xFFE5A00D)),
                    ),
                  Flexible(
                    child: Text(
                      vod.vodName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }


}
