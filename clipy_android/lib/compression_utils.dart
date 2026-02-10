import 'dart:typed_data';
import 'dart:io';
import 'package:archive/archive.dart';

class CompressionUtils {
  static bool shouldCompressFile(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) return false;
    
    // Check file size
    final fileSize = file.lengthSync();
    if (fileSize < 1024) return false; // Less than 1KB
    
    // Check file extension for already compressed files
    final compressedExtensions = [
      'zip', 'gz', '7z', 'rar', 'tar', 'bz2', 'xz',
      'jpg', 'jpeg', 'png', 'gif', 'webp', 'mp4', 'avi', 'mkv',
      'mp3', 'wav', 'flac', 'pdf', 'docx', 'xlsx'
    ];
    
    final extension = filePath.split('.').last.toLowerCase();
    if (compressedExtensions.contains(extension)) {
      return false;
    }
    
    return true;
  }
  
  static Uint8List? compressData(Uint8List data) {
    try {
      // Use gzip compression
      final encoder = GZipEncoder();
      final compressed = encoder.encode(data);

      // Check if compression succeeded and is beneficial
      if (compressed != null && compressed.length < data.length) {
        return Uint8List.fromList(compressed);
      }
    } catch (e) {
      // Compression failed, return null
    }
    return null;
  }

  static Uint8List? decompressData(Uint8List compressedData) {
    try {
      final decoder = GZipDecoder();
      final decompressed = decoder.decodeBytes(compressedData);
      if (decompressed != null) {
        return Uint8List.fromList(decompressed);
      }
    } catch (e) {
      // Decompression failed
    }
    return null;
  }
}