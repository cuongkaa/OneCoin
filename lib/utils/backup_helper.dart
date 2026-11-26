import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

import 'database_helper.dart';

class BackupHelper {
  static const String _sqliteMagicHeader = 'SQLite format 3\u0000';

  /// Kiểm tra file có đúng chuẩn SQLite3 header và chứa các bảng cốt lõi hay không
  static Future<bool> isValidSqliteBackup(File file) async {
    try {
      if (!await file.exists()) return false;
      final length = await file.length();
      if (length < 4096) return false;

      final headerBytes = await file.openRead(0, 16).first;
      if (headerBytes.length < 16) return false;
      final headerStr = latin1.decode(headerBytes.sublist(0, 16));
      if (headerStr != _sqliteMagicHeader) return false;

      // Mở thử ở chế độ read-only để xác minh bảng transactions_table & wallets tồn tại
      final testDb = await openDatabase(file.path, readOnly: true);
      try {
        final tables = await testDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('wallets', 'transactions_table')",
        );
        return tables.length == 2;
      } finally {
        await testDb.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// Sao lưu database ra file .db (đồng bộ WAL checkpoint trước khi copy)
  static Future<File?> backupDatabase() async {
    try {
      final db = await DatabaseHelper.instance.database;
      try {
        await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
      } catch (_) {}

      final dbPath = await getDatabasesPath();
      final dbFilePath = p.join(dbPath, 'expense_manager.db');
      final dbFile = File(dbFilePath);

      if (!await dbFile.exists()) return null;

      final dir = await getTemporaryDirectory();
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final backupPath = '${dir.path}/onemorecoin_backup_$timestamp.db';

      final backupFile = await dbFile.copy(backupPath);
      return backupFile;
    } catch (e) {
      return null;
    }
  }

  /// Chia sẻ file backup
  static Future<void> shareBackup(File file) async {
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }

  /// Khôi phục database từ file .db được chọn (có xác thực SQLite header & bản sao rollback)
  static Future<bool> restoreDatabase() async {
    File? safetyRollbackFile;
    String? dbFilePath;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
      );

      if (result == null || result.files.isEmpty) return false;

      final pickedFile = result.files.first;
      if (pickedFile.path == null) return false;

      final sourceFile = File(pickedFile.path!);
      if (!await isValidSqliteBackup(sourceFile)) {
        return false;
      }

      final dbPath = await getDatabasesPath();
      dbFilePath = p.join(dbPath, 'expense_manager.db');
      final currentDbFile = File(dbFilePath);

      await DatabaseHelper.instance.close();

      if (await currentDbFile.exists()) {
        safetyRollbackFile = await currentDbFile.copy('$dbFilePath.rollback_bak');
      }

      // Xóa WAL/SHM cũ nếu có để tránh xung đột trang dữ liệu
      for (final suffix in ['-wal', '-shm']) {
        final walFile = File('$dbFilePath$suffix');
        if (await walFile.exists()) {
          await walFile.delete();
        }
      }

      await sourceFile.copy(dbFilePath);

      if (safetyRollbackFile != null && await safetyRollbackFile.exists()) {
        await safetyRollbackFile.delete();
      }
      return true;
    } catch (e) {
      // Khôi phục lại bản gốc nếu quá trình copy gặp sự cố
      if (safetyRollbackFile != null && dbFilePath != null && await safetyRollbackFile.exists()) {
        try {
          await safetyRollbackFile.copy(dbFilePath);
          await safetyRollbackFile.delete();
        } catch (_) {}
      }
      return false;
    }
  }
}
