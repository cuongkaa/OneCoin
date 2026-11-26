import 'package:onemorecoin/services/api_service.dart';
import 'package:onemorecoin/utils/database_helper.dart';
import 'package:sqflite/sqflite.dart';

/// Service đồng bộ dữ liệu giữa SQLite local và PostgreSQL Server qua API
class SyncService {
  static final SyncService instance = SyncService._();
  SyncService._();

  static int _boolToInt(dynamic value, {int defaultValue = 0}) {
    if (value == null) return defaultValue;
    if (value is bool) return value ? 1 : 0;
    if (value is num) return value != 0 ? 1 : 0;
    if (value is String) return (value == 'true' || value == '1') ? 1 : 0;
    return defaultValue;
  }

  /// Upload toàn bộ dữ liệu từ SQLite local lên Server
  Future<Map<String, dynamic>> uploadAllData() async {
    try {
      final db = await DatabaseHelper.instance.database;

      final wallets = await db.query('wallets');
      final groups = await db.query('groups');
      final transactions = await db.query('transactions_table');
      final budgets = await db.query('budgets');
      final loans = await db.query('loans');
      final loanPayments = await db.query('loan_payments');
      final reminders = await db.query('reminders');

      final result = await ApiService.instance.syncUpload({
        'wallets': wallets,
        'groups': groups,
        'transactions': transactions,
        'budgets': budgets,
        'loans': loans,
        'loanPayments': loanPayments,
        'reminders': reminders,
      });

      return result;
    } catch (e) {
      return {'success': false, 'error': 'Lỗi đồng bộ: $e'};
    }
  }

  /// Download toàn bộ dữ liệu từ Server về SQLite local
  /// Bọc toàn bộ trong SQLite Transaction để đảm bảo tính nguyên tử (Atomic):
  /// Nếu có bất kỳ lỗi nào xảy ra, SQLite tự động rollback để không làm mất dữ liệu local.
  Future<Map<String, dynamic>> downloadAllData() async {
    try {
      final result = await ApiService.instance.syncDownload();

      if (result['success'] != true || result['data'] is! Map) {
        return result;
      }

      final data = Map<String, dynamic>.from(result['data'] as Map);
      final db = await DatabaseHelper.instance.database;

      await db.transaction((txn) async {
        // Xóa dữ liệu cũ bên trong transaction an toàn
        await txn.delete('loan_payments');
        await txn.delete('loans');
        await txn.delete('transactions_table');
        await txn.delete('budgets');
        await txn.delete('reminders');
        await txn.delete('groups');
        await txn.delete('wallets');

        // 1. Nhập wallets (GIỮ NGUYÊN id để khớp khóa ngoại walletId)
        if (data['wallets'] is List) {
          for (final item in data['wallets']) {
            await txn.insert(
              'wallets',
              {
                if (item['id'] != null) 'id': item['id'],
                'name': item['name'],
                'icon': item['icon'],
                'currency': item['currency'] ?? 'VND',
                'balance': (item['balance'] as num?)?.toDouble() ?? 0.0,
                'isReport': _boolToInt(item['isReport'], defaultValue: 1),
                'index': item['index'] ?? 0,
                'isDeleted': _boolToInt(item['isDeleted']),
                'updatedAt': item['updatedAt']?.toString(),
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }

        // 2. Nhập groups (GIỮ NGUYÊN id để khớp khóa ngoại groupId)
        if (data['groups'] is List) {
          for (final item in data['groups']) {
            await txn.insert(
              'groups',
              {
                if (item['id'] != null) 'id': item['id'],
                'name': item['name'],
                'type': item['type'],
                'icon': item['icon'],
                'color': item['color'],
                'parentId': item['parentId'],
                'index': item['index'] ?? 1,
                'isDeleted': _boolToInt(item['isDeleted']),
                'updatedAt': item['updatedAt']?.toString(),
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }

        // 3. Nhập transactions (bảo toàn categorySource & isDeleted)
        if (data['transactions'] is List) {
          for (final item in data['transactions']) {
            await txn.insert(
              'transactions_table',
              {
                'id': item['id'].toString(),
                'title': item['title'],
                'amount': (item['amount'] as num?)?.toDouble() ?? 0.0,
                'unit': item['unit'] ?? 'VND',
                'type': item['type'],
                'date': item['date'],
                'note': item['note'],
                'addToReport': _boolToInt(item['addToReport'], defaultValue: 1),
                'notifyDate': item['notifyDate'],
                'walletId': item['walletId'],
                'groupId': item['groupId'],
                'categorySource': item['categorySource'],
                'isDeleted': _boolToInt(item['isDeleted']),
                'updatedAt': item['updatedAt']?.toString(),
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }

        // 4. Nhập budgets (GIỮ NGUYÊN id & isDeleted)
        if (data['budgets'] is List) {
          for (final item in data['budgets']) {
            await txn.insert(
              'budgets',
              {
                if (item['id'] != null) 'id': item['id'],
                'title': item['title'],
                'budget': (item['budget'] as num?)?.toDouble() ?? 0.0,
                'unit': item['unit'] ?? 'VND',
                'type': item['type'],
                'fromDate': item['fromDate'],
                'toDate': item['toDate'],
                'note': item['note'],
                'isRepeat': _boolToInt(item['isRepeat']),
                'walletId': item['walletId'],
                'groupId': item['groupId'],
                'budgetType': item['budgetType'] ?? 'month',
                'isDeleted': _boolToInt(item['isDeleted']),
                'updatedAt': item['updatedAt']?.toString(),
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }

        // 5. Nhập loans
        if (data['loans'] is List) {
          for (final item in data['loans']) {
            await txn.insert(
              'loans',
              {
                'id': item['id'].toString(),
                'personName': item['personName'],
                'amount': (item['amount'] as num?)?.toDouble() ?? 0.0,
                'paidAmount': (item['paidAmount'] as num?)?.toDouble() ?? 0.0,
                'type': item['type'],
                'date': item['date'],
                'dueDate': item['dueDate'],
                'note': item['note'],
                'status': item['status'] ?? 'unpaid',
                'currency': item['currency'] ?? 'VND',
                'walletId': item['walletId'],
                'phoneNumber': item['phoneNumber'],
                'remindBeforeDays': item['remindBeforeDays'],
                'remindTime': item['remindTime'],
                'isDeleted': _boolToInt(item['isDeleted']),
                'updatedAt': item['updatedAt']?.toString(),
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }

        // 6. Nhập loan_payments
        if (data['loanPayments'] is List) {
          for (final item in data['loanPayments']) {
            await txn.insert(
              'loan_payments',
              {
                'id': item['id'].toString(),
                'loanId': item['loanId'].toString(),
                'amount': (item['amount'] as num?)?.toDouble() ?? 0.0,
                'date': item['date'],
                'note': item['note'],
                'walletId': item['walletId'],
                'isDeleted': _boolToInt(item['isDeleted']),
                'updatedAt': item['updatedAt']?.toString(),
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }

        // 7. Nhập reminders
        if (data['reminders'] is List) {
          for (final item in data['reminders']) {
            await txn.insert(
              'reminders',
              {
                'id': item['id'].toString(),
                'title': item['title'],
                'amount': (item['amount'] as num?)?.toDouble() ?? 0.0,
                'type': item['type'],
                'dueDate': item['dueDate'],
                'remindBeforeDays': item['remindBeforeDays'] ?? 0,
                'remindTime': item['remindTime'] ?? '08:00',
                'isPaid': _boolToInt(item['isPaid']),
                'note': item['note'],
                'isDeleted': _boolToInt(item['isDeleted']),
                'updatedAt': item['updatedAt']?.toString(),
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
      });

      return {'success': true, 'message': 'Đồng bộ dữ liệu thành công'};
    } catch (e) {
      return {'success': false, 'error': 'Lỗi đồng bộ: $e'};
    }
  }
}
