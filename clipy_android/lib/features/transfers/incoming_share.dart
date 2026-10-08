import 'dart:async';
import 'package:flutter/services.dart';

class SharedFile {
  const SharedFile({
    required this.path,
    required this.name,
    required this.size,
  });
  final String path;
  final String name;
  final int size;
}

class IncomingShare {
  IncomingShare.fromMap(Map<Object?, Object?> value)
    : id = value['id'] as String,
      error = value['error'] as String? ?? '',
      files = [
        for (final file in value['files'] as List<Object?>)
          SharedFile(
            path: (file as Map)['path'] as String,
            name: file['name'] as String,
            size: file['size'] as int,
          ),
      ];
  final String id;
  final String error;
  final List<SharedFile> files;
}

/// Drain one share at a time, only while the UI exists. Native retains batches
/// until the review route closes; duplicate ready/resume events cannot resend.
class IncomingShareCoordinator {
  IncomingShareCoordinator({
    required this.present,
    required this.onError,
    this.channel = const MethodChannel(
      'com.clipyclone.clipy_android/incoming_share',
    ),
  });
  final Future<void> Function(IncomingShare) present;
  final void Function() onError;
  final MethodChannel channel;
  bool _disposed = false;
  bool _draining = false;
  bool _requested = false;

  void start() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'ready') await drain();
    });
    unawaited(drain());
  }

  Future<void> drain() async {
    if (_disposed) return;
    _requested = true;
    if (_draining) return;
    _draining = true;
    try {
      do {
        _requested = false;
        while (!_disposed) {
          final raw = await channel.invokeMapMethod<Object?, Object?>('next');
          if (raw == null || _disposed) break;
          final share = IncomingShare.fromMap(raw);
          await present(share);
          if (_disposed) break;
          await channel.invokeMethod<void>('complete', {'id': share.id});
        }
      } while (_requested && !_disposed);
    } catch (_) {
      if (!_disposed) onError();
    } finally {
      _draining = false;
    }
  }

  void dispose() {
    _disposed = true;
    channel.setMethodCallHandler(null);
  }
}
