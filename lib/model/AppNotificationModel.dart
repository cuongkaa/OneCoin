import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../utils/database_helper.dart';
import '../utils/Utils.dart';

class AppNotificationModel {
  String id;
  String title;
  String body;
  String type; // 'reminder', 'loan', 'system'
  String date; // ISO8601 string payload
  bool isRead;
  String? referenceId;

  AppNotificationModel({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
    required this.date,
    this.isRead = false,
    this.referenceId,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'body': body,
      'type': type,
      'date': date,
      'isRead': isRead ? 1 : 0,
      'referenceId': referenceId,
    };
  }

  factory AppNotificationModel.fromMap(Map<String, dynamic> map) {
    return AppNotificationModel(
      id: map['id'],
      title: map['title'],
      body: map['body'],
      type: map['type'],
      date: map['date'],
      isRead: map['isRead'] == 1,
      referenceId: map['referenceId'],
    );
  }
}

class AppNotificationProvider extends ChangeNotifier {
  List<AppNotificationModel> _notifications = [];
  bool _isLoading = true;
  bool _isSyncing = false;

  List<AppNotificationModel> get notifications => _notifications;
  int get unreadCount => _notifications.where((n) => !n.isRead).length;
  bool get isLoading => _isLoading;

  AppNotificationProvider() {
    init();
  }

  Future<void> init() async {
    _isLoading = true;
    notifyListeners();
    await syncNotifications(forceFetch: true);
  }

  Future<void> fetchAll() async {
    final db = await DatabaseHelper.instance.database;
    final maps = await db.query('app_notifications', orderBy: 'date DESC');
    _notifications = maps.map((e) => AppNotificationModel.fromMap(e)).toList();
    _isLoading = false;
    notifyListeners();
  }

  Future<void> markAsRead(String id) async {
    final idx = _notifications.indexWhere((n) => n.id == id);
    if (idx != -1 && !_notifications[idx].isRead) {
      _notifications[idx].isRead = true;
      notifyListeners();
    }
    final db = await DatabaseHelper.instance.database;
    await db.update('app_notifications', {'isRead': 1}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> markAllAsRead() async {
    for (final n in _notifications) {
      n.isRead = true;
    }
    notifyListeners();
    final db = await DatabaseHelper.instance.database;
    await db.update('app_notifications', {'isRead': 1}, where: 'isRead = 0');
  }

  Future<void> delete(String id) async {
    _notifications.removeWhere((n) => n.id == id);
    notifyListeners();
    final db = await DatabaseHelper.instance.database;
    await db.delete('app_notifications', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteAll() async {
    _notifications.clear();
    notifyListeners();
    final db = await DatabaseHelper.instance.database;
    await db.delete('app_notifications');
  }

  Future<void> addNotification(AppNotificationModel notification) async {
    _notifications.insert(0, notification);
    notifyListeners();
    final db = await DatabaseHelper.instance.database;
    await db.insert('app_notifications', notification.toMap());
  }

  /// Khử hoàn toàn truy vấn N+1: Gộp đọc 3 bảng song song + kiểm tra O(1) qua HashSet + ghi bằng Batch
  Future<void> syncNotifications({bool forceFetch = false}) async {
    if (_isSyncing) return;
    _isSyncing = true;
    try {
      final db = await DatabaseHelper.instance.database;
      final now = DateTime.now();

      final queryResults = await Future.wait([
        db.query('reminders', where: 'isPaid = 0 AND (isDeleted = 0 OR isDeleted IS NULL) AND dueDate IS NOT NULL'),
        db.query('loans', where: 'status != ? AND (isDeleted = 0 OR isDeleted IS NULL) AND dueDate IS NOT NULL', whereArgs: ['paid']),
        db.query('app_notifications', columns: ['referenceId', 'type', 'date']),
      ]);

      final reminders = queryResults[0];
      final loans = queryResults[1];
      final existingKeys = <String>{
        for (final row in queryResults[2])
          '${row['referenceId']}|${row['type']}|${row['date']}',
      };

      final batch = db.batch();
      bool hasNew = false;

      // 1. Check Reminders in O(1) memory lookup
      for (final r in reminders) {
        final dueDateStr = r['dueDate'] as String?;
        if (dueDateStr == null || dueDateStr.isEmpty) continue;
        final dueDate = DateTime.tryParse(dueDateStr);
        if (dueDate == null) continue;

        final remindBeforeDays = (r['remindBeforeDays'] as int?) ?? 0;
        final remindTimeStr = (r['remindTime'] as String?) ?? '08:00';
        final reminderDate = dueDate.subtract(Duration(days: remindBeforeDays));
        final parts = remindTimeStr.split(':');
        final scheduleDate = DateTime(
          reminderDate.year,
          reminderDate.month,
          reminderDate.day,
          int.tryParse(parts[0]) ?? 8,
          int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0,
        );

        if (now.isAfter(scheduleDate)) {
          final scheduleIso = scheduleDate.toIso8601String();
          final lookupKey = '${r['id']}|reminder|$scheduleIso';
          if (existingKeys.add(lookupKey)) {
            final title = r['title'] ?? 'Nhắc thanh toán hoá đơn';
            final amount = r['amount'] != null
                ? Utils.currencyFormat((r['amount'] as num).toDouble(), withoutUnit: true)
                : '0';
            batch.insert('app_notifications', {
              'id': const Uuid().v4(),
              'title': title,
              'body': 'Đến hạn thanh toán $title số tiền $amount',
              'type': 'reminder',
              'date': scheduleIso,
              'isRead': 0,
              'referenceId': r['id'],
            });
            hasNew = true;
          }
        }
      }

      // 2. Check Loans in O(1) memory lookup
      for (final l in loans) {
        final dueDateStr = l['dueDate'] as String?;
        if (dueDateStr == null || dueDateStr.isEmpty) continue;
        final dueDate = DateTime.tryParse(dueDateStr);
        if (dueDate == null) continue;

        final remindBeforeDays = (l['remindBeforeDays'] as int?) ?? 0;
        final remindTimeStr = (l['remindTime'] as String?) ?? '08:00';
        final reminderDate = dueDate.subtract(Duration(days: remindBeforeDays));
        final parts = remindTimeStr.split(':');
        final scheduleDate = DateTime(
          reminderDate.year,
          reminderDate.month,
          reminderDate.day,
          int.tryParse(parts[0]) ?? 8,
          int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0,
        );

        if (now.isAfter(scheduleDate)) {
          final scheduleIso = scheduleDate.toIso8601String();
          final lookupKey = '${l['id']}|loan|$scheduleIso';
          if (existingKeys.add(lookupKey)) {
            final bool isBorrow = l['type'] == 'borrow';
            final title = isBorrow ? 'Khoản nợ đến hạn' : 'Khoản cho vay đến hạn';
            final amount = l['amount'] != null
                ? Utils.currencyFormat((l['amount'] as num).toDouble(), withoutUnit: true)
                : '0';
            final person = l['personName'] ?? '';
            final body = isBorrow
                ? 'Bạn cần trả $amount cho $person'
                : 'Đến hạn thu $amount từ $person';

            batch.insert('app_notifications', {
              'id': const Uuid().v4(),
              'title': title,
              'body': body,
              'type': 'loan',
              'date': scheduleIso,
              'isRead': 0,
              'referenceId': l['id'],
            });
            hasNew = true;
          }
        }
      }

      if (hasNew) {
        await batch.commit(noResult: true);
      }
      if (hasNew || forceFetch) {
        await fetchAll();
      }
    } finally {
      _isSyncing = false;
    }
  }
}
