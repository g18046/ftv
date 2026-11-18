import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class IsoExtent {
  final int offset;
  final int length;

  const IsoExtent({required this.offset, required this.length});
}

class IsoStreamEntry {
  final String name;
  final String path;
  final int totalSize;
  final List<IsoExtent> extents;

  const IsoStreamEntry({
    required this.name,
    required this.path,
    required this.totalSize,
    required this.extents,
  });

  String get ext {
    final idx = name.lastIndexOf('.');
    return idx >= 0 ? name.substring(idx).toLowerCase() : '.m2ts';
  }
}

class IsoParseResult {
  final String discType; // 'BDMV' | 'DVD' | 'ISO'
  final List<IsoStreamEntry> entries;
  final IsoStreamEntry primaryEntry;

  const IsoParseResult({
    required this.discType,
    required this.entries,
    required this.primaryEntry,
  });
}

abstract class _IsoReader {
  Future<int> getTotalSize();
  Future<Uint8List> readAt(int offset, int length);
  Future<void> close();
}

class _LocalIsoReader implements _IsoReader {
  final RandomAccessFile _raf;
  final int _length;

  _LocalIsoReader(this._raf, this._length);

  @override
  Future<int> getTotalSize() async => _length;

  @override
  Future<Uint8List> readAt(int offset, int length) async {
    if (offset < 0 || offset >= _length || length <= 0) {
      return Uint8List(0);
    }
    final toRead = (offset + length > _length) ? (_length - offset) : length;
    await _raf.setPosition(offset);
    return await _raf.read(toRead);
  }

  @override
  Future<void> close() async {
    await _raf.close();
  }
}

class _HttpIsoReader implements _IsoReader {
  final String url;
  final Map<String, String> headers;
  late final HttpClient _client;
  int? _totalSize;
  final Map<int, Uint8List> _blockCache = {};
  static const int _cacheBlockSize = 32768; // 32KB 块缓存，大幅减少目录遍历时的 HTTP Range 请求次数

  _HttpIsoReader(this.url, this.headers) {
    _client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 12)
      ..badCertificateCallback = (cert, host, port) => true;
    _client.userAgent = null;
  }

  void _applyHeaders(HttpClientRequest req) {
    headers.forEach((k, v) {
      final ck = k.trim();
      if (ck.isNotEmpty && v.isNotEmpty) {
        req.headers.set(ck, v);
      }
    });
  }

  @override
  Future<int> getTotalSize() async {
    if (_totalSize != null) return _totalSize!;
    try {
      final req = await _client.openUrl('HEAD', Uri.parse(url));
      _applyHeaders(req);
      final resp = await req.close();
      await resp.drain<void>();
      final cl = resp.headers.value(HttpHeaders.contentLengthHeader);
      final parsed = int.tryParse(cl ?? '');
      if (parsed != null && parsed > 0) {
        _totalSize = parsed;
        return parsed;
      }
    } catch (_) {}

    // Fallback: Range bytes=0-0 获取 Content-Range 总长度
    final req = await _client.openUrl('GET', Uri.parse(url));
    _applyHeaders(req);
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    final resp = await req.close();
    await resp.drain<void>();
    final cr = resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
    final match = RegExp(r'/(\d+)').firstMatch(cr);
    if (match != null) {
      _totalSize = int.tryParse(match.group(1)!) ?? 0;
      return _totalSize!;
    }
    final cl = int.tryParse(resp.headers.value(HttpHeaders.contentLengthHeader) ?? '');
    _totalSize = cl ?? 0;
    return _totalSize!;
  }

  Future<Uint8List> _fetchRange(int start, int endInclusive) async {
    final req = await _client.openUrl('GET', Uri.parse(url));
    _applyHeaders(req);
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$endInclusive');
    final resp = await req.close();
    if (resp.statusCode != 200 && resp.statusCode != 206) {
      await resp.drain<void>();
      throw HttpException('HTTP Range failed: ${resp.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    // 若服务端忽略 Range 返回了完整文件头，只截取需要部分
    if (resp.statusCode == 200 && start > 0 && bytes.length > start) {
      final sliceEnd = (endInclusive + 1 <= bytes.length) ? endInclusive + 1 : bytes.length;
      return Uint8List.sublistView(bytes, start, sliceEnd);
    }
    return bytes;
  }

  @override
  Future<Uint8List> readAt(int offset, int length) async {
    if (offset < 0 || length <= 0) return Uint8List(0);
    final total = await getTotalSize();
    if (total > 0 && offset >= total) return Uint8List(0);
    final clampedLen = (total > 0 && offset + length > total) ? (total - offset) : length;
    if (clampedLen <= 0) return Uint8List(0);

    // 大于 128KB 直接按需读取，不走块缓存
    if (clampedLen > 131072) {
      return _fetchRange(offset, offset + clampedLen - 1);
    }

    final out = BytesBuilder(copy: false);
    int cur = offset;
    int remaining = clampedLen;

    while (remaining > 0) {
      final blockIdx = cur ~/ _cacheBlockSize;
      final blockStart = blockIdx * _cacheBlockSize;
      Uint8List? block = _blockCache[blockIdx];
      if (block == null) {
        final fetchEnd = (total > 0 && blockStart + _cacheBlockSize > total)
            ? total - 1
            : blockStart + _cacheBlockSize - 1;
        block = await _fetchRange(blockStart, fetchEnd);
        if (_blockCache.length > 64) {
          _blockCache.remove(_blockCache.keys.first);
        }
        _blockCache[blockIdx] = block;
      }
      final inBlockOffset = cur - blockStart;
      if (inBlockOffset >= block.length) break;
      final take = (block.length - inBlockOffset < remaining)
          ? (block.length - inBlockOffset)
          : remaining;
      out.add(Uint8List.sublistView(block, inBlockOffset, inBlockOffset + take));
      cur += take;
      remaining -= take;
    }
    return out.takeBytes();
  }

  @override
  Future<void> close() async {
    _blockCache.clear();
    _client.close(force: true);
  }
}

class IsoParserService {
  static const int _sectorSize = 2048;
  static const Set<String> _videoExts = {
    '.m2ts',
    '.mts',
    '.mkv',
    '.mp4',
    '.ts',
    '.vob',
    '.mpg',
    '.mpeg',
    '.avi',
    '.mov',
  };

  static bool isIsoPathOrUrl(String url, {String? episodeName}) {
    final cleanUrl = url.split('?').first.split('#').first.toLowerCase().trim();
    if (cleanUrl.endsWith('.iso')) return true;
    final ep = (episodeName ?? '').toLowerCase().trim();
    if (ep.endsWith('.iso') || ep.contains('.iso ') || ep.contains('.iso[')) {
      return true;
    }
    return false;
  }

  static Future<IsoParseResult?> parse(
    String sourceUrl, {
    Map<String, String> headers = const {},
  }) async {
    _IsoReader? reader;
    try {
      if (sourceUrl.startsWith('http://') || sourceUrl.startsWith('https://')) {
        reader = _HttpIsoReader(sourceUrl, headers);
      } else {
        final path = sourceUrl.startsWith('file://')
            ? Uri.parse(sourceUrl).toFilePath()
            : sourceUrl;
        final file = File(path);
        if (!await file.exists()) return null;
        final len = await file.length();
        final raf = await file.open(mode: FileMode.read);
        reader = _LocalIsoReader(raf, len);
      }

      final totalSize = await reader.getTotalSize();
      if (totalSize < _sectorSize * 20) return null;

      // 1. 优先尝试 UDF 2.50 / 2.01 / 1.02 解析 (蓝光 BDMV 与主流 DVD ISO)
      final udfEntries = await _parseUdf(reader, totalSize);
      if (udfEntries.isNotEmpty) {
        return _buildResult(udfEntries);
      }

      // 2. 回退 ISO9660 解析
      final isoEntries = await _parseIso9660(reader);
      if (isoEntries.isNotEmpty) {
        return _buildResult(isoEntries);
      }

      return null;
    } catch (e) {
      print('⚠️ [ISO-PARSER] 解析失败: $e');
      return null;
    } finally {
      await reader?.close();
    }
  }

  static IsoParseResult _buildResult(List<IsoStreamEntry> rawEntries) {
    final m2tsEntries = rawEntries
        .where((e) => e.ext == '.m2ts' || e.ext == '.mts')
        .toList()
      ..sort((a, b) => b.totalSize.compareTo(a.totalSize));

    if (m2tsEntries.isNotEmpty) {
      return IsoParseResult(
        discType: 'BDMV',
        entries: m2tsEntries,
        primaryEntry: m2tsEntries.first,
      );
    }

    final vobEntries = rawEntries.where((e) => e.ext == '.vob').toList();
    if (vobEntries.isNotEmpty) {
      // 按 DVD Title Set (如 VTS_01_1.VOB, VTS_01_2.VOB...) 合并正片分片
      final Map<String, List<IsoStreamEntry>> titleSets = {};
      for (final vob in vobEntries) {
        final upper = vob.name.toUpperCase();
        final m = RegExp(r'^(VTS_\d+)_(\d+)\.VOB$').firstMatch(upper);
        if (m != null && m.group(2) != '0') {
          titleSets.putIfAbsent(m.group(1)!, () => []).add(vob);
        }
      }
      if (titleSets.isNotEmpty) {
        final mergedSets = <IsoStreamEntry>[];
        titleSets.forEach((prefix, parts) {
          parts.sort((a, b) => a.name.compareTo(b.name));
          final combinedExtents = <IsoExtent>[];
          int total = 0;
          for (final p in parts) {
            combinedExtents.addAll(p.extents);
            total += p.totalSize;
          }
          mergedSets.add(IsoStreamEntry(
            name: '${prefix}_MAIN.VOB',
            path: parts.first.path,
            totalSize: total,
            extents: combinedExtents,
          ));
        });
        mergedSets.sort((a, b) => b.totalSize.compareTo(a.totalSize));
        return IsoParseResult(
          discType: 'DVD',
          entries: mergedSets,
          primaryEntry: mergedSets.first,
        );
      }
      vobEntries.sort((a, b) => b.totalSize.compareTo(a.totalSize));
      return IsoParseResult(
        discType: 'DVD',
        entries: vobEntries,
        primaryEntry: vobEntries.first,
      );
    }

    final sorted = List<IsoStreamEntry>.from(rawEntries)
      ..sort((a, b) => b.totalSize.compareTo(a.totalSize));
    return IsoParseResult(
      discType: 'ISO',
      entries: sorted,
      primaryEntry: sorted.first,
    );
  }

  static int _u16(Uint8List b, int off) => b[off] | (b[off + 1] << 8);

  static int _u32(Uint8List b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  static int _u64(Uint8List b, int off) {
    final lo = _u32(b, off);
    final hi = _u32(b, off + 4);
    return lo + hi * 4294967296;
  }

  static String _decodeUdfString(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    final compId = bytes[0];
    if (compId == 8) {
      return latin1.decode(bytes.sublist(1), allowInvalid: true);
    } else if (compId == 16) {
      final codes = <int>[];
      for (int i = 1; i + 1 < bytes.length; i += 2) {
        codes.add((bytes[i] << 8) | bytes[i + 1]);
      }
      return String.fromCharCodes(codes);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static Future<List<IsoStreamEntry>> _parseUdf(
    _IsoReader reader,
    int totalSize,
  ) async {
    // 查找 AVDP (Anchor Volume Descriptor Pointer, tagId == 2)
    Uint8List? avdp;
    final candidateSectors = [256, (totalSize ~/ _sectorSize) - 256, 512];
    for (final sec in candidateSectors) {
      if (sec <= 0) continue;
      final data = await reader.readAt(sec * _sectorSize, 512);
      if (data.length >= 32 && _u16(data, 0) == 2) {
        avdp = data;
        break;
      }
    }
    if (avdp == null) return [];

    final mvdsLen = _u32(avdp, 16);
    final mvdsLoc = _u32(avdp, 20);
    if (mvdsLen <= 0 || mvdsLen > 1024 * 1024) return [];

    final mvds = await reader.readAt(mvdsLoc * _sectorSize, mvdsLen);
    if (mvds.length < _sectorSize) return [];

    final Map<int, int> physicalPartitions = {};
    int blockSize = _sectorSize;
    int fsdLength = 0;
    int fsdBlock = 0;
    int fsdPartRef = 0;
    Uint8List? lvdBytes;

    for (int off = 0; off + 512 <= mvds.length; off += _sectorSize) {
      final tagId = _u16(mvds, off);
      if (tagId == 8) break; // Terminating Descriptor
      if (tagId == 5) {
        // Partition Descriptor
        final partNum = _u16(mvds, off + 22);
        final partStart = _u32(mvds, off + 188);
        physicalPartitions[partNum] = partStart;
      } else if (tagId == 6) {
        // Logical Volume Descriptor
        lvdBytes = Uint8List.sublistView(mvds, off, off + _sectorSize);
        blockSize = _u32(mvds, off + 212);
        if (blockSize <= 0) blockSize = _sectorSize;
        fsdLength = _u32(mvds, off + 248);
        fsdBlock = _u32(mvds, off + 252);
        fsdPartRef = _u16(mvds, off + 256);
      }
    }

    if (physicalPartitions.isEmpty || lvdBytes == null || fsdLength == 0) {
      return [];
    }

    // 解析 Partition Maps (支持 Type 1 物理分区 & Type 2 UDF 2.50 Metadata Partition)
    final Map<int, int> mapRefToPhysicalPart = {};
    int? metadataMapRef;
    int? metadataUnderlyingPart;
    int? metadataFileLoc;
    int? metadataMirrorLoc;

    final mapTableLen = _u32(lvdBytes, 264);
    final numMaps = _u32(lvdBytes, 268);
    int mapOff = 440;
    for (int i = 0; i < numMaps && mapOff + 2 <= 440 + mapTableLen && mapOff + 2 <= lvdBytes.length; i++) {
      final mapType = lvdBytes[mapOff];
      final mapLen = lvdBytes[mapOff + 1];
      if (mapLen <= 0 || mapOff + mapLen > lvdBytes.length) break;
      if (mapType == 1 && mapLen >= 6) {
        final partNum = _u16(lvdBytes, mapOff + 4);
        mapRefToPhysicalPart[i] = partNum;
      } else if (mapType == 2 && mapLen >= 48) {
        final typeId = latin1.decode(
          Uint8List.sublistView(lvdBytes, mapOff + 5, mapOff + 28),
          allowInvalid: true,
        );
        if (typeId.contains('UDF Metadata')) {
          metadataMapRef = i;
          metadataUnderlyingPart = _u16(lvdBytes, mapOff + 38);
          metadataFileLoc = _u32(lvdBytes, mapOff + 40);
          metadataMirrorLoc = _u32(lvdBytes, mapOff + 44);
        } else {
          final partNum = _u16(lvdBytes, mapOff + 38);
          mapRefToPhysicalPart[i] = partNum;
        }
      }
      mapOff += mapLen;
    }

    // 读取 Metadata File Extents (用于 UDF 2.50 蓝光镜像)
    final List<IsoExtent> metadataFileExtents = [];
    if (metadataMapRef != null && metadataUnderlyingPart != null && metadataFileLoc != null) {
      final physStart = physicalPartitions[metadataUnderlyingPart];
      if (physStart != null) {
        Future<List<IsoExtent>> readMetaFile(int locBlock) async {
          final feBytes = await reader.readAt((physStart + locBlock) * blockSize, blockSize);
          final parsed = _parseFileEntryExtents(
            feBytes,
            blockSize: blockSize,
            defaultPartRef: metadataUnderlyingPart!,
            resolveBlock: (partRef, blk) {
              final ps = physicalPartitions[partRef] ?? physStart;
              return (ps + blk) * blockSize;
            },
          );
          return parsed?.extents ?? [];
        }

        metadataFileExtents.addAll(await readMetaFile(metadataFileLoc));
        if (metadataFileExtents.isEmpty && metadataMirrorLoc != null) {
          metadataFileExtents.addAll(await readMetaFile(metadataMirrorLoc));
        }
      }
    }

    int? resolveLogicalBlockOffset(int partRef, int block) {
      if (partRef == metadataMapRef && metadataFileExtents.isNotEmpty) {
        int byteInMeta = block * blockSize;
        for (final ext in metadataFileExtents) {
          if (byteInMeta < ext.length) {
            return ext.offset + byteInMeta;
          }
          byteInMeta -= ext.length;
        }
        return null;
      }
      final physPartNum = mapRefToPhysicalPart[partRef] ?? partRef;
      final physStart = physicalPartitions[physPartNum];
      if (physStart == null) return null;
      return (physStart + block) * blockSize;
    }

    // 读取 File Set Descriptor (tagId == 256)
    final fsdOffset = resolveLogicalBlockOffset(fsdPartRef, fsdBlock);
    if (fsdOffset == null) return [];
    final fsdBytes = await reader.readAt(fsdOffset, blockSize);
    if (fsdBytes.length < 416 || _u16(fsdBytes, 0) != 256) return [];

    // Root Directory ICB (Long AD at offset 400)
    final rootIcbBlock = _u32(fsdBytes, 404);
    final rootIcbPart = _u16(fsdBytes, 408);

    final results = <IsoStreamEntry>[];

    Future<void> walkDirectory(
      int dirBlock,
      int dirPart,
      String currentPath,
      int depth,
    ) async {
      if (depth > 4) return;
      final feOffset = resolveLogicalBlockOffset(dirPart, dirBlock);
      if (feOffset == null) return;
      final feBytes = await reader.readAt(feOffset, blockSize);
      final dirEntry = await _readFileEntryFull(
        reader,
        feBytes,
        blockSize: blockSize,
        defaultPartRef: dirPart,
        resolveBlock: resolveLogicalBlockOffset,
      );
      if (dirEntry == null) return;

      Uint8List dirData;
      if (dirEntry.inlineData != null) {
        dirData = dirEntry.inlineData!;
      } else {
        if (dirEntry.infoLength > 8 * 1024 * 1024) return;
        final builder = BytesBuilder(copy: false);
        for (final ext in dirEntry.extents) {
          builder.add(await reader.readAt(ext.offset, ext.length));
        }
        dirData = builder.takeBytes();
      }

      int pos = 0;
      while (pos + 38 <= dirData.length) {
        final tagId = _u16(dirData, pos);
        if (tagId != 257) break;
        final chars = dirData[pos + 18];
        final lenFi = dirData[pos + 19];
        final icbBlock = _u32(dirData, pos + 24);
        final icbPart = _u16(dirData, pos + 28);
        final lenIu = _u16(dirData, pos + 36);
        final recLen = ((38 + lenIu + lenFi + 3) ~/ 4) * 4;
        if (recLen <= 0 || pos + recLen > dirData.length) break;

        final isParent = (chars & 0x08) != 0;
        final isDeleted = (chars & 0x04) != 0;
        final isDir = (chars & 0x02) != 0;

        if (!isParent && !isDeleted && lenFi > 0) {
          final fiBytes = Uint8List.sublistView(
            dirData,
            pos + 38 + lenIu,
            pos + 38 + lenIu + lenFi,
          );
          final name = _decodeUdfString(fiBytes).trim();
          if (name.isNotEmpty) {
            final fullPath = currentPath.isEmpty ? name : '$currentPath/$name';
            if (isDir) {
              final upper = name.toUpperCase();
              // 蓝光只深入 BDMV -> STREAM，DVD 深入 VIDEO_TS，或普通目录
              if (depth == 0 ||
                  upper == 'BDMV' ||
                  upper == 'STREAM' ||
                  upper == 'VIDEO_TS' ||
                  currentPath.isEmpty) {
                await walkDirectory(icbBlock, icbPart, fullPath, depth + 1);
              }
            } else {
              final dot = name.lastIndexOf('.');
              final ext = dot >= 0 ? name.substring(dot).toLowerCase() : '';
              if (_videoExts.contains(ext)) {
                final fileFeOff = resolveLogicalBlockOffset(icbPart, icbBlock);
                if (fileFeOff != null) {
                  final fileFeBytes = await reader.readAt(fileFeOff, blockSize);
                  final fileParsed = await _readFileEntryFull(
                    reader,
                    fileFeBytes,
                    blockSize: blockSize,
                    defaultPartRef: icbPart,
                    resolveBlock: resolveLogicalBlockOffset,
                  );
                  if (fileParsed != null &&
                      fileParsed.infoLength > 0 &&
                      fileParsed.extents.isNotEmpty) {
                    results.add(IsoStreamEntry(
                      name: name,
                      path: fullPath,
                      totalSize: fileParsed.infoLength,
                      extents: fileParsed.extents,
                    ));
                  }
                }
              }
            }
          }
        }
        pos += recLen;
      }
    }

    await walkDirectory(rootIcbBlock, rootIcbPart, '', 0);
    return results;
  }

  static Future<_UdfFileParsed?> _readFileEntryFull(
    _IsoReader reader,
    Uint8List feBytes, {
    required int blockSize,
    required int defaultPartRef,
    required int? Function(int partRef, int block) resolveBlock,
  }) async {
    final base = _parseFileEntryExtents(
      feBytes,
      blockSize: blockSize,
      defaultPartRef: defaultPartRef,
      resolveBlock: resolveBlock,
    );
    if (base == null) return null;

    // 处理 Allocation Extent Descriptor (continuation extent, type == 3)
    var nextLoc = base.continuationBlock;
    var nextPart = base.continuationPart;
    var nextLen = base.continuationLen;
    int guard = 0;
    while (nextLoc != null && nextLen > 0 && guard < 16) {
      guard++;
      final off = resolveBlock(nextPart ?? defaultPartRef, nextLoc);
      if (off == null) break;
      final aed = await reader.readAt(off, nextLen);
      if (aed.length < 24 || _u16(aed, 0) != 258) break;
      final adLen = _u32(aed, 20);
      final cont = _parseAllocationDescriptors(
        aed,
        24,
        adLen,
        adType: base.adType,
        defaultPartRef: defaultPartRef,
        resolveBlock: resolveBlock,
        outExtents: base.extents,
      );
      nextLoc = cont.nextBlock;
      nextPart = cont.nextPart;
      nextLen = cont.nextLen;
    }

    // 修正最后一个分片的实际文件长度 (infoLength)
    if (base.extents.isNotEmpty && base.infoLength > 0) {
      int sum = 0;
      for (final e in base.extents) {
        sum += e.length;
      }
      if (sum > base.infoLength) {
        final excess = sum - base.infoLength;
        final last = base.extents.last;
        if (last.length > excess) {
          base.extents[base.extents.length - 1] = IsoExtent(
            offset: last.offset,
            length: last.length - excess,
          );
        }
      }
    }
    return base;
  }

  static _UdfFileParsed? _parseFileEntryExtents(
    Uint8List feBytes, {
    required int blockSize,
    required int defaultPartRef,
    required int? Function(int partRef, int block) resolveBlock,
  }) {
    if (feBytes.length < 180) return null;
    final tagId = _u16(feBytes, 0);
    if (tagId != 261 && tagId != 266) return null;

    final icbFlags = _u16(feBytes, 34);
    final adType = icbFlags & 0x07;
    final infoLength = _u64(feBytes, 56);

    final int eaLenOff = tagId == 261 ? 168 : 208;
    final int adLenOff = tagId == 261 ? 172 : 212;
    final int adStartBase = tagId == 261 ? 176 : 216;
    if (feBytes.length < adStartBase) return null;

    final eaLen = _u32(feBytes, eaLenOff);
    final adLen = _u32(feBytes, adLenOff);
    final adStart = adStartBase + eaLen;
    if (adStart > feBytes.length) return null;

    if (adType == 3) {
      final end = (adStart + adLen <= feBytes.length) ? adStart + adLen : feBytes.length;
      return _UdfFileParsed(
        infoLength: infoLength,
        adType: adType,
        extents: [],
        inlineData: Uint8List.sublistView(feBytes, adStart, end),
      );
    }

    final extents = <IsoExtent>[];
    final cont = _parseAllocationDescriptors(
      feBytes,
      adStart,
      adLen,
      adType: adType,
      defaultPartRef: defaultPartRef,
      resolveBlock: resolveBlock,
      outExtents: extents,
    );

    return _UdfFileParsed(
      infoLength: infoLength,
      adType: adType,
      extents: extents,
      continuationBlock: cont.nextBlock,
      continuationPart: cont.nextPart,
      continuationLen: cont.nextLen,
    );
  }

  static _AdContinuation _parseAllocationDescriptors(
    Uint8List buf,
    int start,
    int len, {
    required int adType,
    required int defaultPartRef,
    required int? Function(int partRef, int block) resolveBlock,
    required List<IsoExtent> outExtents,
  }) {
    final end = (start + len <= buf.length) ? start + len : buf.length;
    int pos = start;
    final step = adType == 0 ? 8 : (adType == 1 ? 16 : 20);

    while (pos + step <= end) {
      final rawLen = _u32(buf, pos);
      final extType = (rawLen >> 30) & 0x03;
      final byteLen = rawLen & 0x3FFFFFFF;
      if (byteLen == 0) {
        pos += step;
        continue;
      }

      if (adType == 0) {
        final blk = _u32(buf, pos + 4);
        if (extType == 3) {
          return _AdContinuation(nextBlock: blk, nextPart: defaultPartRef, nextLen: byteLen);
        }
        if (extType == 0 || extType == 1) {
          final off = resolveBlock(defaultPartRef, blk);
          if (off != null) {
            outExtents.add(IsoExtent(offset: off, length: byteLen));
          }
        }
      } else if (adType == 1) {
        final blk = _u32(buf, pos + 4);
        final partRef = _u16(buf, pos + 8);
        if (extType == 3) {
          return _AdContinuation(nextBlock: blk, nextPart: partRef, nextLen: byteLen);
        }
        if (extType == 0 || extType == 1) {
          final off = resolveBlock(partRef, blk);
          if (off != null) {
            outExtents.add(IsoExtent(offset: off, length: byteLen));
          }
        }
      }
      pos += step;
    }
    return const _AdContinuation();
  }

  static Future<List<IsoStreamEntry>> _parseIso9660(_IsoReader reader) async {
    final pvd = await reader.readAt(16 * _sectorSize, _sectorSize);
    if (pvd.length < 190 ||
        pvd[0] != 1 ||
        latin1.decode(Uint8List.sublistView(pvd, 1, 6), allowInvalid: true) != 'CD001') {
      return [];
    }

    int blockSize = _u16(pvd, 128);
    if (blockSize <= 0) blockSize = _sectorSize;

    final rootExtent = _u32(pvd, 156 + 2);
    final rootSize = _u32(pvd, 156 + 10);
    final results = <IsoStreamEntry>[];

    Future<void> walkDir(int sector, int size, String curPath, int depth) async {
      if (depth > 4 || size <= 0 || size > 4 * 1024 * 1024) return;
      final data = await reader.readAt(sector * blockSize, size);
      int pos = 0;
      while (pos < data.length) {
        final recLen = data[pos];
        if (recLen == 0) {
          // 跳到下一个扇区边界
          final nextSec = ((pos ~/ blockSize) + 1) * blockSize;
          if (nextSec >= data.length) break;
          pos = nextSec;
          continue;
        }
        if (pos + recLen > data.length || recLen < 34) break;
        final extLoc = _u32(data, pos + 2);
        final dataLen = _u32(data, pos + 10);
        final flags = data[pos + 25];
        final idLen = data[pos + 32];
        if (pos + 33 + idLen <= data.length && idLen > 0) {
          var name = latin1.decode(
            Uint8List.sublistView(data, pos + 33, pos + 33 + idLen),
            allowInvalid: true,
          );
          if (name != '\x00' && name != '\x01') {
            final semi = name.indexOf(';');
            if (semi > 0) name = name.substring(0, semi);
            final fullPath = curPath.isEmpty ? name : '$curPath/$name';
            final isDir = (flags & 0x02) != 0;
            if (isDir) {
              await walkDir(extLoc, dataLen, fullPath, depth + 1);
            } else {
              final dot = name.lastIndexOf('.');
              final ext = dot >= 0 ? name.substring(dot).toLowerCase() : '';
              if (_videoExts.contains(ext) && dataLen > 0) {
                results.add(IsoStreamEntry(
                  name: name,
                  path: fullPath,
                  totalSize: dataLen,
                  extents: [IsoExtent(offset: extLoc * blockSize, length: dataLen)],
                ));
              }
            }
          }
        }
        pos += recLen;
      }
    }

    await walkDir(rootExtent, rootSize, '', 0);
    return results;
  }
}

class _UdfFileParsed {
  final int infoLength;
  final int adType;
  final List<IsoExtent> extents;
  final Uint8List? inlineData;
  final int? continuationBlock;
  final int? continuationPart;
  final int continuationLen;

  _UdfFileParsed({
    required this.infoLength,
    required this.adType,
    required this.extents,
    this.inlineData,
    this.continuationBlock,
    this.continuationPart,
    this.continuationLen = 0,
  });
}

class _AdContinuation {
  final int? nextBlock;
  final int? nextPart;
  final int nextLen;

  const _AdContinuation({this.nextBlock, this.nextPart, this.nextLen = 0});
}
