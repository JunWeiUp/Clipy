import 'dart:typed_data';
import 'dart:io';

class CompressionUtils {
  // Keep these rules aligned with macOS SyncManager.shouldCompressFile so both
  // sides make the same compression decision for the same file.
  static const Set<String> _neverCompressExtensions = {
    // Archives and compressed files
    'zip', 'gz', '7z', 'rar', 'tar', 'bz2', 'xz', 'tgz', 'tbz2',
    // Images
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'tiff', 'svg', 'ico',
    // Video
    'mp4', 'avi', 'mkv', 'mov', 'wmv', 'flv', 'webm', 'm4v',
    // Audio
    'mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'wma',
    // Documents
    'pdf', 'docx', 'xlsx', 'pptx', 'epub', 'mobi',
    // Executables and binaries
    'exe', 'dll', 'so', 'dylib', 'app', 'apk', 'ipa', 'bin', 'dmg',
    // Other compressed or binary formats
    'psd', 'ai', 'indd', 'raw', 'cr2', 'nef', 'arw',
  };

  static const Set<String> _textExtensions = {
    'txt', 'log', 'csv', 'json', 'xml', 'html', 'htm', 'css', 'js', 'ts',
    'py', 'java', 'cpp', 'c', 'h', 'hpp', 'cs', 'rb', 'php', 'go', 'rs',
    'swift', 'kt', 'kts', 'md', 'markdown', 'yaml', 'yml', 'toml', 'ini',
    'properties', 'cfg', 'conf', 'sh', 'bash', 'bat', 'cmd', 'sql', 'pl',
    'pm', 'lua', 'r', 'scala', 'clj', 'cljs', 'edn', 'coffee', 'scss', 'sass',
  };

  static Future<bool> shouldCompressFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return false;

    final extension = filePath.split('.').last.toLowerCase();
    if (_neverCompressExtensions.contains(extension)) {
      return false;
    }
    if (!_textExtensions.contains(extension)) {
      return _isLikelyTextFile(file);
    }

    final fileSize = await file.length();
    if (fileSize < 1024) return false; // Less than 1KB
    if (fileSize > 10 * 1024 * 1024) return false; // More than 10MB

    return true;
  }

  static Future<bool> _isLikelyTextFile(File file) async {
    try {
      final raf = await file.open();
      try {
        final data = await raf.read(1024);
        if (data.isEmpty) return false;
        if (data.contains(0)) return false;

        var printableCount = 0;
        for (final byte in data) {
          if ((byte >= 32 && byte <= 126) || byte == 9 || byte == 10 || byte == 13) {
            printableCount++;
          }
        }
        return printableCount / data.length > 0.9;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  static Uint8List? compressData(Uint8List data) {
    try {
      final compressed = gzip.encode(data);
      if (compressed.length < data.length) {
        return Uint8List.fromList(compressed);
      }
    } catch (_) {
      // Not beneficial or failed; caller sends uncompressed.
    }
    return null;
  }

  static Uint8List? decompressData(Uint8List compressedData) {
    try {
      final decompressed = gzip.decode(compressedData);
      return Uint8List.fromList(decompressed);
    } catch (_) {
      // Caller must treat this as a fatal chunk error.
    }
    return null;
  }
}
