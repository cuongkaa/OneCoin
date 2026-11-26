import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  static Future<Database>? _initFuture;

  DatabaseHelper._init();

  /// Cho phép gắn Database giả lập (ví dụ WebPrefsDatabase) khi chạy kiểm thử tự động
  static void setDatabaseForTesting(Database? db) {
    _database = db;
    _initFuture = db != null ? Future.value(db) : null;
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _initFuture ??= _openAppropriateDb();
    try {
      _database = await _initFuture!;
      return _database!;
    } catch (e) {
      _initFuture = null;
      rethrow;
    }
  }

  Future<Database> _openAppropriateDb() async {
    if (kIsWeb) {
      final webDb = WebPrefsDatabase();
      await webDb.init();
      return webDb;
    }
    return await _initDB('expense_manager.db');
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 12,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
      onOpen: (db) async {
        try {
          await db.rawQuery('PRAGMA journal_mode = WAL');
          await db.execute('PRAGMA synchronous = NORMAL');
        } catch (_) {}
      },
    );
  }

  Future<void> _createIndexes(Database db) async {
    const indexStatements = [
      'CREATE INDEX IF NOT EXISTS idx_tx_date ON transactions_table(date DESC)',
      'CREATE INDEX IF NOT EXISTS idx_tx_wallet_del ON transactions_table(walletId, isDeleted)',
      'CREATE INDEX IF NOT EXISTS idx_tx_group_del ON transactions_table(groupId, isDeleted)',
      'CREATE INDEX IF NOT EXISTS idx_budgets_wallet_del ON budgets(walletId, isDeleted)',
      'CREATE INDEX IF NOT EXISTS idx_loans_status_del ON loans(status, isDeleted)',
      'CREATE INDEX IF NOT EXISTS idx_loan_payments_loan_del ON loan_payments(loanId, isDeleted)',
      'CREATE INDEX IF NOT EXISTS idx_pending_status_id ON pending_actions(status, id)',
      'CREATE INDEX IF NOT EXISTS idx_pending_lookup ON pending_actions(tableName, recordId, status)',
      'CREATE INDEX IF NOT EXISTS idx_notif_ref ON app_notifications(referenceId, type, date)',
    ];
    for (final sql in indexStatements) {
      try {
        await db.execute(sql);
      } catch (_) {}
    }
  }

  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    const idType = 'TEXT PRIMARY KEY';
    const textType = 'TEXT';
    const integerType = 'INTEGER';
    const realType = 'REAL';

    if (oldVersion < 3) {
      await db.execute('''
CREATE TABLE IF NOT EXISTS reminders (
  id $idType,
  title $textType,
  amount $realType,
  type $textType,
  dueDate $textType,
  remindBeforeDays $integerType,
  remindTime $textType,
  isPaid $integerType,
  note $textType
)
''');
    }
    if (oldVersion < 4) {
      try {
        await db.execute('ALTER TABLE reminders ADD COLUMN remindTime $textType DEFAULT "08:00"');
      } catch (_) {}
    }
    if (oldVersion < 5) {
      await db.execute('''
CREATE TABLE IF NOT EXISTS loans (
  id $idType,
  personName $textType,
  amount $realType,
  paidAmount $realType,
  type $textType,
  date $textType,
  dueDate $textType,
  note $textType,
  status $textType,
  currency $textType
)
''');

      await db.execute('''
CREATE TABLE IF NOT EXISTS loan_payments (
  id $idType,
  loanId $textType,
  amount $realType,
  date $textType,
  note $textType
)
''');

      try {
        await db.execute('ALTER TABLE groups ADD COLUMN color $textType');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE groups ADD COLUMN parentId $integerType');
      } catch (_) {}
    }
    if (oldVersion < 6) {
      try {
        await db.execute('ALTER TABLE loans ADD COLUMN walletId $integerType');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE loan_payments ADD COLUMN walletId $integerType');
      } catch (_) {}
    }
    if (oldVersion < 7) {
      try {
        await db.execute('ALTER TABLE loans ADD COLUMN phoneNumber $textType');
      } catch (_) {}
    }
    if (oldVersion < 8) {
      try {
        await db.execute('ALTER TABLE loans ADD COLUMN remindBeforeDays $integerType');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE loans ADD COLUMN remindTime $textType');
      } catch (_) {}
    }
    if (oldVersion < 9) {
      await db.execute('''
CREATE TABLE IF NOT EXISTS app_notifications (
  id $idType,
  title $textType,
  body $textType,
  type $textType,
  date $textType,
  isRead $integerType,
  referenceId $textType
)
''');
    }
    if (oldVersion < 10) {
      await db.execute('''
CREATE TABLE IF NOT EXISTS pending_actions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tableName $textType,
  actionType $textType,
  recordId $textType,
  payload $textType,
  requestId $textType,
  status $textType DEFAULT 'pending',
  retryCount $integerType DEFAULT 0,
  createdAt $textType,
  lastAttempt $textType
)
''');

      final tables = ['wallets', 'groups', 'transactions_table', 'budgets', 'reminders', 'loans', 'loan_payments'];
      for (final table in tables) {
        try {
          await db.execute('ALTER TABLE $table ADD COLUMN isDeleted $integerType DEFAULT 0');
        } catch (_) {}
        try {
          await db.execute('ALTER TABLE $table ADD COLUMN updatedAt $textType');
        } catch (_) {}
      }
    }
    if (oldVersion < 11) {
      try {
        await db.execute('ALTER TABLE transactions_table ADD COLUMN categorySource TEXT');
      } catch (_) {}
    }
    if (oldVersion < 12) {
      await _createIndexes(db);
    }
  }

  Future _createDB(Database db, int version) async {
    const idType = 'TEXT PRIMARY KEY';
    const integerIdType = 'INTEGER PRIMARY KEY AUTOINCREMENT';
    const textType = 'TEXT';
    const integerType = 'INTEGER';
    const realType = 'REAL';

    await db.execute('''
CREATE TABLE users (
  id $textType PRIMARY KEY,
  username $textType,
  email $textType,
  password $textType
)
''');

    await db.execute('''
CREATE TABLE wallets (
  id $integerIdType,
  name $textType,
  icon $textType,
  currency $textType,
  balance $realType,
  isReport $integerType,
  "index" $integerType,
  isDeleted $integerType DEFAULT 0,
  updatedAt $textType
)
''');

    await db.execute('''
CREATE TABLE groups (
  id $integerIdType,
  name $textType,
  icon $textType,
  type $textType,
  "index" $integerType,
  color $textType,
  parentId $integerType,
  isDeleted $integerType DEFAULT 0,
  updatedAt $textType
)
''');

    await db.execute('''
CREATE TABLE transactions_table (
  id $idType,
  title $textType,
  amount $realType,
  unit $textType,
  type $textType,
  date $textType,
  note $textType,
  addToReport $integerType,
  notifyDate $textType,
  walletId $integerType,
  groupId $integerType,
  categorySource $textType,
  isDeleted $integerType DEFAULT 0,
  updatedAt $textType,
  FOREIGN KEY (walletId) REFERENCES wallets (id),
  FOREIGN KEY (groupId) REFERENCES groups (id)
)
''');

    await db.execute('''
CREATE TABLE budgets (
  id $integerIdType,
  title $textType,
  budget $realType,
  unit $textType,
  type $textType,
  fromDate $textType,
  toDate $textType,
  note $textType,
  isRepeat $integerType,
  walletId $integerType,
  groupId $integerType,
  budgetType $textType,
  isDeleted $integerType DEFAULT 0,
  updatedAt $textType,
  FOREIGN KEY (walletId) REFERENCES wallets (id),
  FOREIGN KEY (groupId) REFERENCES groups (id)
)
''');

    await db.execute('''
CREATE TABLE reminders (
  id $idType,
  title $textType,
  amount $realType,
  type $textType,
  dueDate $textType,
  remindBeforeDays $integerType,
  remindTime $textType,
  isPaid $integerType,
  note $textType,
  isDeleted $integerType DEFAULT 0,
  updatedAt $textType
)
''');

    await db.execute('''
CREATE TABLE loans (
  id $idType,
  personName $textType,
  amount $realType,
  paidAmount $realType,
  type $textType,
  date $textType,
  dueDate $textType,
  note $textType,
  status $textType,
  currency $textType,
  walletId $integerType,
  phoneNumber $textType,
  remindBeforeDays $integerType,
  remindTime $textType,
  isDeleted $integerType DEFAULT 0,
  updatedAt $textType
)
''');

    await db.execute('''
CREATE TABLE loan_payments (
  id $idType,
  loanId $textType,
  amount $realType,
  date $textType,
  note $textType,
  walletId $integerType,
  isDeleted $integerType DEFAULT 0,
  updatedAt $textType
)
''');

    await db.execute('''
CREATE TABLE app_notifications (
  id $idType,
  title $textType,
  body $textType,
  type $textType,
  date $textType,
  isRead $integerType,
  referenceId $textType
)
''');

    await db.execute('''
CREATE TABLE pending_actions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tableName $textType,
  actionType $textType,
  recordId $textType,
  payload $textType,
  requestId $textType,
  status $textType DEFAULT 'pending',
  retryCount $integerType DEFAULT 0,
  createdAt $textType,
  lastAttempt $textType
)
''');

    await _createIndexes(db);
  }

  Future<void> clearUserData() async {
    final db = await instance.database;
    final batch = db.batch();
    batch.delete('pending_actions');
    batch.delete('loan_payments');
    batch.delete('loans');
    batch.delete('transactions_table');
    batch.delete('budgets');
    batch.delete('reminders');
    batch.delete('groups');
    batch.delete('wallets');
    batch.delete('app_notifications');
    await batch.commit(noResult: true);
  }

  Future close() async {
    final db = await instance.database;
    _database = null;
    _initFuture = null;
    await db.close();
  }
}

// ============================================================================
// WEB DATABASE ENGINE (Dành riêng cho Chrome / Flutter Web - lưu trên localStorage)
// Giúp toàn bộ tính năng Đăng ký/Đăng nhập Offline & Online, Ví, Giao dịch, Ngân sách
// chạy mượt trên trình duyệt Chrome mà không bị lỗi "databaseFactory not initialized".
// ============================================================================
class WebPrefsDatabase implements Database, Transaction {
  static const List<String> _knownTables = [
    'users',
    'wallets',
    'groups',
    'transactions_table',
    'budgets',
    'reminders',
    'loans',
    'loan_payments',
    'app_notifications',
    'pending_actions',
  ];

  static const Set<String> _autoIncrementTables = {
    'wallets',
    'groups',
    'budgets',
    'pending_actions',
  };

  final Map<String, List<Map<String, Object?>>> _store = {};
  SharedPreferences? _prefs;
  bool _isOpen = false;

  Future<void> init() async {
    if (_isOpen) return;
    _prefs = await SharedPreferences.getInstance();
    for (final t in _knownTables) {
      final raw = _prefs!.getString('__webdb_$t');
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw) as List;
          _store[t] = decoded
              .map((e) => Map<String, Object?>.from(e as Map))
              .toList();
        } catch (_) {
          _store[t] = [];
        }
      } else {
        _store[t] = [];
      }
    }
    _isOpen = true;
  }

  Future<void> _persistTable(String table) async {
    final rows = _store[table] ?? const [];
    await _prefs?.setString('__webdb_$table', jsonEncode(rows));
  }

  List<Map<String, Object?>> _tableRows(String table) {
    return _store.putIfAbsent(table, () => []);
  }

  @override
  String get path => 'web_local_storage.db';

  @override
  bool get isOpen => _isOpen;

  @override
  Future<void> close() async {
    _isOpen = false;
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {}

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    final rows = _tableRows(table);
    final row = Map<String, Object?>.from(values);

    if (_autoIncrementTables.contains(table) && row['id'] == null) {
      int maxId = 0;
      for (final existing in rows) {
        final eid = existing['id'];
        if (eid is int && eid > maxId) maxId = eid;
      }
      row['id'] = maxId + 1;
    }

    row.putIfAbsent('isDeleted', () => 0);

    final idVal = row['id'];
    if (idVal != null) {
      final existingIdx = rows.indexWhere((r) => '${r['id']}' == '$idVal');
      if (existingIdx != -1) {
        if (conflictAlgorithm == ConflictAlgorithm.ignore) {
          return existingIdx;
        }
        rows[existingIdx] = row;
        await _persistTable(table);
        return idVal is int ? idVal : existingIdx + 1;
      }
    }

    rows.add(row);
    await _persistTable(table);
    return (row['id'] is int) ? (row['id'] as int) : rows.length;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    final rows = _tableRows(table);
    Iterable<Map<String, Object?>> filtered = rows.where(
      (row) => _matchesWhere(row, where, whereArgs),
    );

    List<Map<String, Object?>> resultList = filtered
        .map((r) => Map<String, Object?>.from(r))
        .toList();

    if (orderBy != null && orderBy.trim().isNotEmpty) {
      final firstOrder = orderBy.split(',').first.trim();
      final parts = firstOrder.split(RegExp(r'\s+'));
      final col = parts[0].replaceAll('"', '');
      final desc = parts.length > 1 && parts[1].toUpperCase() == 'DESC';
      resultList.sort((a, b) {
        final va = a[col];
        final vb = b[col];
        int cmp;
        if (va is num && vb is num) {
          cmp = va.compareTo(vb);
        } else {
          cmp = '${va ?? ''}'.compareTo('${vb ?? ''}');
        }
        return desc ? -cmp : cmp;
      });
    }

    if (offset != null && offset > 0) {
      resultList = offset >= resultList.length ? [] : resultList.sublist(offset);
    }
    if (limit != null && limit >= 0 && limit < resultList.length) {
      resultList = resultList.sublist(0, limit);
    }

    if (columns != null && columns.isNotEmpty) {
      resultList = resultList.map((r) {
        return {
          for (final c in columns) c: r[c],
        };
      }).toList();
    }

    return resultList;
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    final rows = _tableRows(table);
    int count = 0;
    for (int i = 0; i < rows.length; i++) {
      if (_matchesWhere(rows[i], where, whereArgs)) {
        rows[i] = {...rows[i], ...values};
        count++;
      }
    }
    if (count > 0) {
      await _persistTable(table);
    }
    return count;
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final rows = _tableRows(table);
    if (where == null || where.trim().isEmpty) {
      final removed = rows.length;
      rows.clear();
      await _persistTable(table);
      return removed;
    }
    final before = rows.length;
    rows.removeWhere((row) => _matchesWhere(row, where, whereArgs));
    final removed = before - rows.length;
    if (removed > 0) {
      await _persistTable(table);
    }
    return removed;
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async {
    final normalized = sql.trim();
    if (normalized.toUpperCase().startsWith('PRAGMA')) {
      return [];
    }
    final countMatch = RegExp(
      r"SELECT\s+COUNT\(\*\)\s+as\s+count\s+FROM\s+(\w+)(?:\s+WHERE\s+(.+))?",
      caseSensitive: false,
    ).firstMatch(normalized);
    if (countMatch != null) {
      final table = countMatch.group(1)!;
      final where = countMatch.group(2);
      final rows = await query(table, where: where, whereArgs: arguments);
      return [
        {'count': rows.length}
      ];
    }
    return [];
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async => 0;

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action, {bool? exclusive}) async {
    // Snapshot trước khi chạy transaction để hỗ trợ rollback hoàn chỉnh trên Web
    final backup = <String, String>{
      for (final entry in _store.entries) entry.key: jsonEncode(entry.value),
    };
    try {
      return await action(this);
    } catch (e) {
      for (final entry in backup.entries) {
        final decoded = jsonDecode(entry.value) as List;
        _store[entry.key] = decoded
            .map((item) => Map<String, Object?>.from(item as Map))
            .toList();
        await _persistTable(entry.key);
      }
      rethrow;
    }
  }

  @override
  Batch batch() => _WebBatch(this);

  // Bộ phân tích biểu thức điều kiện SQL WHERE hỗ trợ AND, OR, ngoặc đơn (), =, !=, IS NULL, IS NOT NULL
  static bool _matchesWhere(Map<String, Object?> row, String? where, List<Object?>? whereArgs) {
    if (where == null || where.trim().isEmpty) return true;
    int argIdx = 0;
    // Thay thế các dấu ? theo thứ tự thành token an toàn __ARG_0__, __ARG_1__...
    final parameterized = where.replaceAllMapped(RegExp(r'\?'), (_) {
      final token = '__ARG_${argIdx}__';
      argIdx++;
      return token;
    });
    return _evalExpr(row, parameterized.trim(), whereArgs ?? const []);
  }

  static String _stripOuterParens(String expr) {
    var s = expr.trim();
    while (s.startsWith('(') && s.endsWith(')')) {
      int depth = 0;
      bool wrapsAll = true;
      for (int i = 0; i < s.length; i++) {
        if (s[i] == '(') depth++;
        if (s[i] == ')') depth--;
        if (depth == 0 && i < s.length - 1) {
          wrapsAll = false;
          break;
        }
      }
      if (wrapsAll) {
        s = s.substring(1, s.length - 1).trim();
      } else {
        break;
      }
    }
    return s;
  }

  static List<String> _splitTopLevel(String expr, String keyword) {
    final parts = <String>[];
    int depth = 0;
    bool inSingleQuote = false;
    int lastSplit = 0;
    final kwLen = keyword.length;

    for (int i = 0; i < expr.length; i++) {
      final ch = expr[i];
      if (ch == "'") inSingleQuote = !inSingleQuote;
      if (!inSingleQuote) {
        if (ch == '(') depth++;
        if (ch == ')') depth--;
        if (depth == 0 && i + kwLen <= expr.length) {
          final slice = expr.substring(i, i + kwLen);
          final prevOk = i == 0 || RegExp(r'[\s)]').hasMatch(expr[i - 1]);
          final nextOk = i + kwLen == expr.length || RegExp(r'[\s(]').hasMatch(expr[i + kwLen]);
          if (prevOk && nextOk && slice.toUpperCase() == keyword) {
            parts.add(expr.substring(lastSplit, i).trim());
            lastSplit = i + kwLen;
            i += kwLen - 1;
          }
        }
      }
    }
    parts.add(expr.substring(lastSplit).trim());
    return parts;
  }

  static bool _evalExpr(Map<String, Object?> row, String rawExpr, List<Object?> args) {
    final expr = _stripOuterParens(rawExpr);

    final orParts = _splitTopLevel(expr, 'OR');
    if (orParts.length > 1) {
      return orParts.any((p) => _evalExpr(row, p, args));
    }

    final andParts = _splitTopLevel(expr, 'AND');
    if (andParts.length > 1) {
      return andParts.every((p) => _evalExpr(row, p, args));
    }

    final isNotNullMatch = RegExp(r'^"?(\w+)"?\s+IS\s+NOT\s+NULL$', caseSensitive: false).firstMatch(expr);
    if (isNotNullMatch != null) {
      return row[isNotNullMatch.group(1)!] != null;
    }

    final isNullMatch = RegExp(r'^"?(\w+)"?\s+IS\s+NULL$', caseSensitive: false).firstMatch(expr);
    if (isNullMatch != null) {
      return row[isNullMatch.group(1)!] == null;
    }

    final cmpMatch = RegExp(r'^"?(\w+)"?\s*(!=|=)\s*(.+)$').firstMatch(expr);
    if (cmpMatch != null) {
      final col = cmpMatch.group(1)!;
      final op = cmpMatch.group(2)!;
      final rhsRaw = cmpMatch.group(3)!.trim();
      final lhsVal = row[col];
      final rhsVal = _resolveRhs(rhsRaw, args);

      final isEq = _valuesEqual(lhsVal, rhsVal);
      return op == '=' ? isEq : !isEq;
    }

    return true;
  }

  static Object? _resolveRhs(String rhs, List<Object?> args) {
    final argMatch = RegExp(r'^__ARG_(\d+)__$').firstMatch(rhs);
    if (argMatch != null) {
      final idx = int.parse(argMatch.group(1)!);
      return idx < args.length ? args[idx] : null;
    }
    if ((rhs.startsWith("'") && rhs.endsWith("'")) ||
        (rhs.startsWith('"') && rhs.endsWith('"'))) {
      return rhs.substring(1, rhs.length - 1);
    }
    final numVal = num.tryParse(rhs);
    if (numVal != null) return numVal;
    return rhs;
  }

  static bool _valuesEqual(Object? a, Object? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a is num && b is num) return a == b;
    return '$a' == '$b';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WebBatch implements Batch {
  final WebPrefsDatabase _db;
  final List<Future<Object?> Function()> _ops = [];

  _WebBatch(this._db);

  @override
  void insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    _ops.add(() => _db.insert(table, values, conflictAlgorithm: conflictAlgorithm));
  }

  @override
  void update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    _ops.add(() => _db.update(table, values, where: where, whereArgs: whereArgs));
  }

  @override
  void delete(String table, {String? where, List<Object?>? whereArgs}) {
    _ops.add(() => _db.delete(table, where: where, whereArgs: whereArgs));
  }

  @override
  Future<List<Object?>> commit({bool? exclusive, bool? noResult, bool? continueOnError}) async {
    final results = <Object?>[];
    for (final op in _ops) {
      final r = await op();
      if (noResult != true) results.add(r);
    }
    _ops.clear();
    return results;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
