import 'dart:async';
import 'dart:math';
import 'package:flutter/cupertino.dart';
import '../Objects/ShowType.dart';
import '../Objects/TabTransaction.dart';
import '../utils/MyDateUtils.dart';
import '../utils/Utils.dart';
import '../utils/database_helper.dart';
import '../services/sync_queue.dart';
import 'GroupModel.dart';
import 'WalletModel.dart';

class CategorySource {
  static const String userManual = 'user_manual';
  static const String mlSuggestedAccepted = 'ml_suggested_accepted';
  static const String mlSuggestedIgnored = 'ml_suggested_ignored';
  static const String quickChip = 'quick_chip';
}

class TransactionModel {
  String id;
  String? title;
  double? amount;
  String? unit;
  String? type;
  String? _date;
  DateTime? _parsedDateCache;
  bool _dateParsed = false;
  String? note;
  bool? addToReport;
  String? notifyDate;
  int walletId;
  int groupId;
  String? categorySource;

  WalletModel? wallet;
  GroupModel? group;

  TransactionModel(
    this.id, {
    this.title,
    this.amount,
    this.unit = "VND",
    this.type = "income",
    String? date,
    this.note,
    this.addToReport = true,
    this.notifyDate,
    required this.walletId,
    required this.groupId,
    this.categorySource,
    this.wallet,
    this.group,
  }) : _date = date;

  String? get date => _date;
  set date(String? value) {
    _date = value;
    _dateParsed = false;
    _parsedDateCache = null;
  }

  /// Cache DateTime đã parse để không phải gọi DateTime.parse hàng nghìn lần khi sort/filter
  DateTime? get parsedDate {
    if (!_dateParsed) {
      _parsedDateCache = (_date != null && _date!.isNotEmpty) ? DateTime.tryParse(_date!) : null;
      _dateParsed = true;
    }
    return _parsedDateCache;
  }

  int get dateEpochMs => parsedDate?.millisecondsSinceEpoch ?? 0;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'amount': amount,
      'unit': unit,
      'type': type,
      'date': _date,
      'note': note,
      'addToReport': (addToReport ?? true) ? 1 : 0,
      'notifyDate': notifyDate,
      'walletId': walletId,
      'groupId': groupId,
      'categorySource': categorySource,
      'updatedAt': DateTime.now().toIso8601String(),
    };
  }

  factory TransactionModel.fromMap(Map<String, dynamic> map, {WalletModel? wallet, GroupModel? group}) {
    return TransactionModel(
      map['id'].toString(),
      title: map['title'],
      amount: (map['amount'] as num?)?.toDouble(),
      unit: map['unit'],
      type: map['type'],
      date: map['date'],
      note: map['note'],
      addToReport: map['addToReport'] == 1,
      notifyDate: map['notifyDate'],
      walletId: map['walletId'] ?? 0,
      groupId: map['groupId'] ?? 0,
      categorySource: map['categorySource'] as String?,
      wallet: wallet,
      group: group,
    );
  }
}

class TransactionModelProxy extends ChangeNotifier {
  List<TransactionModel> _transactions = [];
  Map<int, WalletModel> _walletMap = {};
  Map<int, GroupModel> _groupMap = {};
  List<TabTransaction> listTab = [];
  ShowType showType = ShowType.date;
  WalletModel _walletModel = WalletModel(0, name: null, icon: null, currency: "VND");
  bool _isLoading = true;

  TransactionModelProxy() {
    init();
  }

  bool get isLoading => _isLoading;

  Future<void> init() async {
    _isLoading = true;
    notifyListeners();
    await fetchAll(notify: false);
    showType = ShowType.date;
    generateListTabTransactionInTransactionPage(true, showType, walletModel);
  }

  WalletModel get walletModel => _walletModel;

  set walletModel(WalletModel value) {
    _walletModel = value;
    generateListTabTransactionInTransactionPage(true, showType, value);
  }

  Future<void> fetchAll({bool notify = true}) async {
    final db = await DatabaseHelper.instance.database;

    // Truy vấn song song cả 3 bảng và dựng Hash Map O(1) thay vì tìm kiếm tuyến tính O(N*M)
    final results = await Future.wait([
      db.query('transactions_table', where: 'isDeleted = 0 OR isDeleted IS NULL'),
      db.query('wallets', where: 'isDeleted = 0 OR isDeleted IS NULL'),
      db.query('groups', where: 'isDeleted = 0 OR isDeleted IS NULL'),
    ]);

    final maps = results[0];
    _walletMap = {
      for (final e in results[1]) (e['id'] as int): WalletModel.fromMap(e),
    };
    _groupMap = {
      for (final e in results[2]) (e['id'] as int): GroupModel.fromMap(e),
    };

    _transactions = maps.map((e) {
      final t = TransactionModel.fromMap(e);
      t.wallet = _walletMap[t.walletId];
      t.group = _groupMap[t.groupId];
      return t;
    }).toList();

    _transactions.sort((a, b) => b.dateEpochMs.compareTo(a.dateEpochMs));
    _isLoading = false;
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> _ensureLookupMapsLoaded(TransactionModel t) async {
    if ((t.wallet == null && !_walletMap.containsKey(t.walletId)) ||
        (t.group == null && !_groupMap.containsKey(t.groupId))) {
      final db = await DatabaseHelper.instance.database;
      final res = await Future.wait([
        db.query('wallets', where: 'isDeleted = 0 OR isDeleted IS NULL'),
        db.query('groups', where: 'isDeleted = 0 OR isDeleted IS NULL'),
      ]);
      _walletMap = {for (final e in res[0]) (e['id'] as int): WalletModel.fromMap(e)};
      _groupMap = {for (final e in res[1]) (e['id'] as int): GroupModel.fromMap(e)};
    }
    t.wallet ??= _walletMap[t.walletId];
    t.group ??= _groupMap[t.groupId];
  }

  TransactionModel getById(String id) {
    if (_transactions.isEmpty) {
      return TransactionModel("0", walletId: 0, groupId: 0, title: "Loading...");
    }
    return _transactions.firstWhere((t) => t.id == id, orElse: () => _transactions.first);
  }

  TransactionModel getByPosition(int position) {
    if (_transactions.isEmpty) {
      return TransactionModel("0", walletId: 0, groupId: 0, title: "Loading...");
    }
    if (position >= 0 && position < _transactions.length) {
      return _transactions[position];
    }
    return _transactions.first;
  }

  List<TransactionModel> getAll() => _transactions;

  List<TransactionModel> getAllByDate(DateTime fromDate, DateTime toDate) {
    final startMs = fromDate.millisecondsSinceEpoch - 1000;
    final endMs = toDate.millisecondsSinceEpoch + 1000;
    return _transactions.where((e) {
      final ms = e.dateEpochMs;
      return ms > startMs && ms < endMs;
    }).toList();
  }

  List<TransactionModel> getNewest(int limit) {
    return _transactions.sublist(0, min(_transactions.length, limit));
  }

  List<TransactionModel> getAllByWalletId(int walletId) {
    if (walletId == 0) return List.from(_transactions);
    return _transactions.where((t) => t.walletId == walletId).toList();
  }

  List<TransactionModel> getLimitByGroup(int groupId, int limit) {
    final list = groupId == 0
        ? List<TransactionModel>.from(_transactions)
        : _transactions.where((t) => t.groupId == groupId).toList();
    if (list.length <= limit) return list;
    return list.sublist(list.length - limit, list.length);
  }

  /// Thêm giao dịch tức thì trên RAM + ghi SQLite, đẩy SyncQueue bất đồng bộ và chỉ notify 1 lần
  Future<void> add(TransactionModel transaction) async {
    final payload = transaction.toMap();
    final db = await DatabaseHelper.instance.database;
    await db.insert('transactions_table', payload);
    await _ensureLookupMapsLoaded(transaction);

    _transactions.add(transaction);
    _transactions.sort((a, b) => b.dateEpochMs.compareTo(a.dateEpochMs));
    listTab = generateListTabTransactionInTransactionPage(true, showType, walletModel);

    unawaited(SyncQueue.instance.enqueue(
      tableName: 'transactions_table',
      actionType: 'create',
      recordId: transaction.id,
      payload: payload,
    ));
  }

  /// Cập nhật giao dịch trực tiếp trên RAM (<1ms), không đọc lại toàn bộ 3 bảng từ đĩa
  Future<void> update(TransactionModel transaction) async {
    final payload = transaction.toMap();
    final db = await DatabaseHelper.instance.database;
    await db.update('transactions_table', payload, where: 'id = ?', whereArgs: [transaction.id]);
    await _ensureLookupMapsLoaded(transaction);

    final idx = _transactions.indexWhere((t) => t.id == transaction.id);
    if (idx != -1) {
      _transactions[idx] = transaction;
    } else {
      _transactions.add(transaction);
    }
    _transactions.sort((a, b) => b.dateEpochMs.compareTo(a.dateEpochMs));
    listTab = generateListTabTransactionInTransactionPage(true, showType, walletModel);

    unawaited(SyncQueue.instance.enqueue(
      tableName: 'transactions_table',
      actionType: 'update',
      recordId: transaction.id,
      payload: payload,
    ));
  }

  Future<void> delete(TransactionModel transaction) => deleteById(transaction.id);

  Future<void> deleteById(String id) async {
    final db = await DatabaseHelper.instance.database;
    final now = DateTime.now().toIso8601String();
    await db.update('transactions_table', {'isDeleted': 1, 'updatedAt': now}, where: 'id = ?', whereArgs: [id]);

    _transactions.removeWhere((t) => t.id == id);
    listTab = generateListTabTransactionInTransactionPage(true, showType, walletModel);

    unawaited(SyncQueue.instance.enqueue(
      tableName: 'transactions_table',
      actionType: 'delete',
      recordId: id,
      payload: {'id': id, 'isDeleted': 1},
    ));
  }

  Future<void> deleteAll() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('transactions_table');
    _transactions.clear();
    listTab = generateListTabTransactionInTransactionPage(true, showType, walletModel);
  }

  List<TransactionModel> getAllForBudget(int groupId, int walletId, String? fromDate, String? toDate) {
    Iterable<TransactionModel> filtered = _transactions.where((t) => t.type == 'expense');
    if (groupId != 0 && walletId != 0) {
      filtered = filtered.where((t) => t.groupId == groupId && t.walletId == walletId);
    } else if (groupId != 0) {
      filtered = filtered.where((t) => t.groupId == groupId);
    } else if (walletId != 0) {
      filtered = filtered.where((t) => t.walletId == walletId);
    }

    if (fromDate != null && toDate != null) {
      final parsedFrom = DateTime.tryParse(fromDate);
      final parsedTo = DateTime.tryParse(toDate);
      if (parsedFrom != null && parsedTo != null) {
        final startMs = DateTime(parsedFrom.year, parsedFrom.month, parsedFrom.day, 0, 0, 0).millisecondsSinceEpoch;
        final endMs = DateTime(parsedTo.year, parsedTo.month, parsedTo.day, 23, 59, 59, 999).millisecondsSinceEpoch;
        filtered = filtered.where((element) {
          final ms = element.dateEpochMs;
          return ms >= startMs && ms <= endMs;
        });
      }
    }
    final list = filtered.toList()
      ..sort((a, b) => b.dateEpochMs.compareTo(a.dateEpochMs));
    return list;
  }

  List<TransactionModel> getTransactionByWalletId(int walletId) {
    if (walletId == 0) return _transactions;
    return _transactions.where((element) => element.walletId == walletId).toList();
  }

  List<TabTransaction> generateListTabTransactionInTransactionPage(
    bool require,
    ShowType showTypeRequest,
    WalletModel walletModelRequest,
  ) {
    if (showType == showTypeRequest && _walletModel.id == walletModelRequest.id && !require) {
      return listTab;
    }
    showType = showTypeRequest;
    _walletModel = walletModelRequest;
    final listTabNoTransaction = Utils.getListTabShowTypeTransaction(showTypeRequest, 20);
    listTab
      ..clear()
      ..addAll(listTabNoTransaction);

    final transactions = getTransactionByWalletId(_walletModel.id);
    for (final tran in transactions) {
      final dt = tran.parsedDate;
      if (dt == null) continue;
      for (final tab in listTab) {
        if (tab.isAll) {
          tab.transactions.add(tran);
          break;
        }
        if (tab.isFuture) {
          if (MyDateUtils.isAfter(dt, tab.from)) {
            tab.transactions.add(tran);
            break;
          }
        } else {
          if (MyDateUtils.isBetween(dt, tab.from, tab.to)) {
            tab.transactions.add(tran);
            break;
          }
        }
      }
    }
    notifyListeners();
    return listTab;
  }
}
