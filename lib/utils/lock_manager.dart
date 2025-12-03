import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class LockInfo {
  final String user;
  final DateTime timestamp;

  LockInfo({required this.user, required this.timestamp});

  factory LockInfo.fromJson(Map<String, dynamic> json) {
    return LockInfo(
      user: json['user'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'user': user,
        'timestamp': timestamp.toIso8601String(),
      };
}

class LockManager {
  static File _getLockFile(String jsonFilePath) {
    return File('$jsonFilePath.lock');
  }

  /// ロック確認 (他人がロックしていれば情報を返す)
  static Future<LockInfo?> checkLock(String jsonFilePath) async {
    final lockFile = _getLockFile(jsonFilePath);
    if (await lockFile.exists()) {
      try {
        final content = await lockFile.readAsString();
        final json = jsonDecode(content);
        return LockInfo.fromJson(json);
      } catch (e) {
        // 壊れたロックファイル等は無視するか、不明なロックとして扱う
        return LockInfo(user: '不明なユーザー', timestamp: await lockFile.lastModified());
      }
    }
    return null;
  }

  /// ロック取得
  static Future<void> acquireLock(String jsonFilePath, String userName) async {
    final lockFile = _getLockFile(jsonFilePath);
    final info = LockInfo(user: userName, timestamp: DateTime.now());
    await lockFile.writeAsString(jsonEncode(info.toJson()));
    debugPrint('Lock acquired: ${lockFile.path} by $userName');
  }

  /// ロック解放
  static Future<void> releaseLock(String jsonFilePath) async {
    final lockFile = _getLockFile(jsonFilePath);
    if (await lockFile.exists()) {
      await lockFile.delete();
      debugPrint('Lock released: ${lockFile.path}');
    }
  }
}