import 'package:onemorecoin/model/GroupModel.dart';
import 'package:onemorecoin/utils/database_helper.dart';

/// Offline recommendation based on previous notes and Vietnamese intent words.
class SmartCategorizerService {
  static const Map<String, List<String>> keywords = {
    'Ăn uống': [
      'highlands',
      'phúc long',
      'cafe',
      'cà phê',
      'trà sữa',
      'phở',
      'cơm',
      'bún',
      'ăn uống'
    ],
    'Di chuyển': [
      'grab',
      'petrolimex',
      'taxi',
      'đổ xăng',
      'vé xe',
      'di chuyển'
    ],
    'Mua sắm': [
      'winmart',
      'co.opmart',
      'siêu thị',
      'tạp hóa',
      'mua sắm',
      'aeon'
    ],
    'Sức khỏe': ['bệnh viện', 'nhà thuốc', 'khám bệnh'],
    'Giải trí': ['rạp phim', 'xem phim', 'netflix', 'game'],
    'Tiền nhà': ['tiền nhà', 'thuê nhà'],
    'Tiền nước': ['tiền nước', 'cấp nước'],
    'Tiền internet': ['internet', 'wifi', 'vnpt'],
    'Tiền điện thoại': ['điện thoại', 'nạp thẻ', 'viettel'],
    'Tiền học': ['học phí', 'tiền học'],
  };

  static String normalize(String text) =>
      text.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  /// [history] is injectable for deterministic tests; production reads SQLite.
  static Future<int?> suggestCategory(String text, List<GroupModel> groups,
      {List<Map<String, dynamic>>? history}) async {
    final input = normalize(text);
    if (input.isEmpty) return null;
    final available = {
      for (final g in groups.where((g) => g.type == 'expense')) g.id: g
    };
    if (available.isEmpty) return null;
    final rows = history ??
        await (await DatabaseHelper.instance.database).query(
          'transactions_table',
          columns: ['note', 'groupId'],
          where: "type = ? AND (isDeleted = 0 OR isDeleted IS NULL)",
          whereArgs: ['expense'],
        );
    final votes = <int, int>{};
    // Match complete merchant or note first; then match meaningful overlapping tokens.
    final tokens = input
        .split(RegExp(r'[^a-z0-9à-ỹ]+'))
        .where((w) => w.length >= 3)
        .toSet();
    for (final row in rows) {
      final id = row['groupId'];
      if (id is! int || !available.containsKey(id)) continue;
      final note = normalize(row['note']?.toString() ?? '');
      if (note.isEmpty) continue;
      final noteTokens = note.split(RegExp(r'[^a-z0-9à-ỹ]+')).toSet();
      final overlap = tokens.intersection(noteTokens).length;
      final score = input == note
          ? 6
          : (note.contains(input) || input.contains(note))
              ? 3
              : overlap;
      if (score > 0) votes[id] = (votes[id] ?? 0) + score;
    }
    if (votes.isNotEmpty) {
      final ranked = votes.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      return ranked.first.key;
    }
    for (final entry in keywords.entries) {
      if (entry.value.any((word) => input.contains(word))) {
        for (final group in available.values) {
          if (normalize(group.name ?? '') == normalize(entry.key))
            return group.id;
        }
      }
    }
    return null;
  }
}
