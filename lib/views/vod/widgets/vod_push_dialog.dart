import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../repositories/site_repository.dart';
import '../../detail/detail_view.dart';

Future<void> showVodPushDialog(
  BuildContext context,
  SiteRepository repository,
  bool Function() isMounted,
) async {
  final controller = TextEditingController();

  try {
    final clipData = await Clipboard.getData(Clipboard.kTextPlain);
    final clipText = clipData?.text?.trim() ?? '';
    if (clipText.isNotEmpty) {
      controller.text = clipText;
      controller.selection =
          TextSelection(baseOffset: 0, extentOffset: clipText.length);
    }
  } catch (_) {}

  if (!isMounted()) return;

  Future<void> submitLink(BuildContext dialogCtx) async {
    final link = controller.text.trim();
    if (link.isEmpty) return;
    Navigator.pop(dialogCtx);
    final pushVod = await repository.pushLink(link);
    if (isMounted()) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DetailView(
            repository: repository,
            vodItem: pushVod,
            vodId: pushVod?.vodId ?? link,
          ),
        ),
      );
    }
  }

  showDialog(
    context: context,
    builder: (dialogCtx) => Dialog(
      backgroundColor: const Color(0xFFF3EFF6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '播放',
                style: TextStyle(
                  color: Colors.black87,
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: controller,
                style: const TextStyle(color: Colors.black87, fontSize: 15),
                maxLines: 2,
                minLines: 1,
                onSubmitted: (_) => submitLink(dialogCtx),
                decoration: InputDecoration(
                  hintText: '请输入地址...',
                  hintStyle: const TextStyle(color: Colors.black54, fontSize: 15),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Colors.black54, width: 1),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF1976D2), width: 1.5),
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.folder_outlined,
                        color: Colors.black54, size: 24),
                    tooltip: '选择本地媒体文件',
                    onPressed: () async {
                      try {
                        final picked = await FilePicker.pickFile(
                          type: FileType.any,
                        );
                        final path = picked?.path;
                        if (path != null && path.isNotEmpty) {
                          controller.text = Uri.file(path).toString();
                          controller.selection = TextSelection.collapsed(
                              offset: path.length);
                        }
                      } catch (_) {}
                    },
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  TextButton(
                    onPressed: () => submitLink(dialogCtx),
                    child: const Text(
                      '推送',
                      style: TextStyle(
                        color: Color(0xFF1976D2),
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx),
                    child: const Text(
                      '取消',
                      style: TextStyle(
                        color: Color(0xFF1976D2),
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => submitLink(dialogCtx),
                    child: const Text(
                      '确定',
                      style: TextStyle(
                        color: Color(0xFF1976D2),
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
