import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:onemorecoin/model/GroupModel.dart';
import 'package:onemorecoin/utils/database_helper.dart';

class CategoryPrediction {
  final int groupId;
  final String groupName;
  final double confidence;
  final String source; // 'personal_history_nb', 'pretrained_tfidf_nb', 'keyword_prior'

  const CategoryPrediction({
    required this.groupId,
    required this.groupName,
    required this.confidence,
    required this.source,
  });
}

/// Hybrid On-Device ML Categorizer combining:
/// 1. Online Incremental Learning from personal SQLite history (N-gram + Naive Bayes)
/// 2. Pre-trained TF-IDF + Multinomial Naive Bayes model (`assets/models/expense_classifier_model.json`)
/// 3. Vietnamese Intent Keyword Dictionary Prior
class SmartCategorizerService {
  static Map<String, dynamic>? _pretrainedModel;
  static bool _modelLoadAttempted = false;

  static const Set<String> _stopwords = {
    'va', 'cua', 'tai', 'cho', 'voi', 'cac', 'nhung', 'mot', 'nay', 'kia',
    'la', 'o', 'trong', 'ngoai', 'khi', 'ma', 'de', 'do',
    // Từ khóa hành chính / chân trang biên lai xuất hiện ở mọi hóa đơn (tránh nhiễu Naive Bayes)
    'thanh', 'toan', 'tong', 'cong', 'khach', 'dua', 'thua', 'tra', 'lai',
    'ngay', 'thang', 'nam', 'vnd', 'dong', 'hoa', 'don', 'bien', 'so',
  };

  static const Set<String> _unigramOnlyStopwords = {
    'tien', 'tiền', 'thanh', 'toán', 'tổng', 'cộng', 'khách', 'đưa', 'thừa',
    'ngày', 'tháng', 'năm', 'hóa', 'đơn', 'biên', 'truy', 'cập', 'xem', 'thêm',
    'phiếu', 'tạm', 'tính', 'thu', 'ngân', 'phục', 'vụ',
  };

  /// Các âm tiết không dấu ngắn dễ trùng nghĩa khi mất dấu tiếng Việt (ví dụ 'cập' -> 'cap' trùng 'cấp nước')
  /// Vẫn giữ nguyên trong Bigram ('cap_nuoc', 'cap_quang', 'ban_do'), chỉ loại khỏi Unigram không dấu đơn lẻ
  static const Set<String> _ambiguousAsciiUnigrams = {
    'cap', 'ban', 'anh', 'thu', 'chi', 'con', 'hai', 'ba', 'tu', 'sau', 'bay',
    'tam', 'chin', 'muoi', 'gia', 'moi', 'cao', 'nho', 'lon', 'tot', 'xem',
    'truy', 'phieu', 'tinh', 'ngan', 'phuc', 'vu',
  };

  static const Map<String, List<String>> keywords = {
    'Ăn uống': [
      'highlands',
      'phúc long',
      'phuc long',
      'the coffee house',
      'starbucks',
      'katinat',
      'cafe',
      'cà phê',
      'ca phe',
      'trà sữa',
      'tra sua',
      'phở',
      'pho',
      'cơm',
      'com',
      'bún',
      'bun',
      'bánh mì',
      'banh mi',
      'lẩu',
      'lau',
      'nướng',
      'kfc',
      'lotteria',
      'jollibee',
      'pizza',
      'gogi',
      'haidilao',
      'mixue',
      'gong cha',
      'ăn sáng',
      'ăn trưa',
      'ăn tối',
      'ăn uống',
      'nhà hàng',
      'quán ăn',
      'cơm gà',
      'cơm tấm',
      'ba chỉ',
      'hải sản',
      'bàn ',
    ],
    'Di chuyển': [
      'grab',
      'grabbike',
      'grabcar',
      'petrolimex',
      'pvoil',
      'xanh sm',
      'be group',
      'bebike',
      'becar',
      'mai linh',
      'vinasun',
      'futa',
      'phương trang',
      'vietjet',
      'vietnam airlines',
      'vetc',
      'epass',
      'taxi',
      'đổ xăng',
      'do xang',
      'xăng',
      'vé xe',
      'gửi xe',
      'di chuyển',
    ],
    'Mua sắm': [
      'winmart',
      'co.opmart',
      'coopmart',
      'aeon',
      'big c',
      'lotte mart',
      'bách hóa xanh',
      'bach hoa xanh',
      'circle k',
      'familymart',
      'gs25',
      '7-eleven',
      'shopee',
      'lazada',
      'tiki',
      'uniqlo',
      'thế giới di động',
      'điện máy xanh',
      'fpt shop',
      'cellphones',
      'hasaki',
      'guardian',
      'siêu thị',
      'tạp hóa',
      'mua sắm',
    ],
    'Sức khỏe': [
      'bệnh viện',
      'benh vien',
      'nhà thuốc',
      'nha thuoc',
      'long châu',
      'long chau',
      'pharmacity',
      'an khang',
      'vinmec',
      'tâm anh',
      'nha khoa',
      'vnvc',
      'khám bệnh',
      'tiêm chủng',
      'thuốc',
      'gym',
      'yoga',
    ],
    'Giải trí': [
      'rạp phim',
      'xem phim',
      'cgv',
      'lotte cinema',
      'galaxy cinema',
      'bhd star',
      'netflix',
      'spotify',
      'youtube premium',
      'steam',
      'karaoke',
      'vinwonders',
      'sun world',
      'game',
    ],
    'Tiền nhà': [
      'tiền nhà',
      'tien nha',
      'thuê nhà',
      'thue nha',
      'tiền trọ',
      'phòng trọ',
      'chung cư',
    ],
    'Tiền điện': [
      'evn',
      'evnhcmc',
      'evnhanoi',
      'evnspc',
      'evncpc',
      'evnnpc',
      'điện lực',
      'dien luc',
      'tiền điện',
      'tien dien',
    ],
    'Tiền nước': [
      'tiền nước',
      'tien nuoc',
      'cấp nước',
      'cap nuoc',
      'sawaco',
      'hawaco',
    ],
    'Tiền internet': [
      'internet',
      'wifi',
      'vnpt',
      'fpt telecom',
      'cáp quang',
      'cap quang',
      'tiền mạng',
    ],
    'Tiền điện thoại': [
      'điện thoại',
      'dien thoai',
      'nạp thẻ',
      'nap the',
      'viettel',
      'mobifone',
      'vinaphone',
      'vietnamobile',
      '4g',
      '5g',
    ],
    'Tiền học': [
      'học phí',
      'hoc phi',
      'tiền học',
      'tien hoc',
      'ila',
      'vus',
      'ielts',
      'fahasa',
      'coursera',
      'udemy',
    ],
  };

  static String normalize(String text) =>
      text.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Remove Vietnamese diacritics so OCR text missing accents still matches features.
  static String removeDiacritics(String text) {
    const vietnameseMap = {
      'à': 'a', 'á': 'a', 'ả': 'a', 'ã': 'a', 'ạ': 'a',
      'ă': 'a', 'ằ': 'a', 'ắ': 'a', 'ẳ': 'a', 'ẵ': 'a', 'ặ': 'a',
      'â': 'a', 'ầ': 'a', 'ấ': 'a', 'ẩ': 'a', 'ẫ': 'a', 'ậ': 'a',
      'đ': 'd',
      'è': 'e', 'é': 'e', 'ẻ': 'e', 'ẽ': 'e', 'ẹ': 'e',
      'ê': 'e', 'ề': 'e', 'ế': 'e', 'ể': 'e', 'ễ': 'e', 'ệ': 'e',
      'ì': 'i', 'í': 'i', 'ỉ': 'i', 'ĩ': 'i', 'ị': 'i',
      'ò': 'o', 'ó': 'o', 'ỏ': 'o', 'õ': 'o', 'ọ': 'o',
      'ô': 'o', 'ồ': 'o', 'ố': 'o', 'ổ': 'o', 'ỗ': 'o', 'ộ': 'o',
      'ơ': 'o', 'ờ': 'o', 'ớ': 'o', 'ở': 'o', 'ỡ': 'o', 'ợ': 'o',
      'ù': 'u', 'ú': 'u', 'ủ': 'u', 'ũ': 'u', 'ụ': 'u',
      'ư': 'u', 'ừ': 'u', 'ứ': 'u', 'ử': 'u', 'ữ': 'u', 'ự': 'u',
      'ỳ': 'y', 'ý': 'y', 'ỷ': 'y', 'ỹ': 'y', 'ỵ': 'y',
    };
    final buffer = StringBuffer();
    for (int i = 0; i < text.length; i++) {
      final ch = text[i];
      buffer.write(vietnameseMap[ch] ?? ch);
    }
    return buffer.toString();
  }

  /// Extract unigram + bigram features (both accented and non-accented),
  /// matching the Python training pipeline (`ml_training/train_and_export.py`).
  static List<String> extractFeatures(String text) {
    final norm = normalize(text);
    final words = norm
        .split(RegExp(r'[^a-z0-9à-ỹ]+'))
        .where((w) => w.length >= 2 && int.tryParse(w) == null)
        .toList();
    final asciiWords = removeDiacritics(norm)
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) =>
            w.length >= 2 &&
            int.tryParse(w) == null &&
            !_stopwords.contains(w))
        .toList();

    final features = <String>[];
    // Sinh Bigram trước (giữ nguyên cụm ngữ nghĩa quan trọng như 'tiền_điện', 'tien_nuoc', 'tien_nha', 'tien_hoc')
    for (int i = 0; i < words.length - 1; i++) {
      features.add('${words[i]}_${words[i + 1]}');
    }
    for (int i = 0; i < asciiWords.length - 1; i++) {
      features.add('${asciiWords[i]}_${asciiWords[i + 1]}');
    }
    // Lọc các từ đơn chung chung ('tiền', 'thanh', 'toán'...) khỏi Unigram để thương hiệu & mặt hàng quyết định nhãn
    for (final w in words) {
      if (!_unigramOnlyStopwords.contains(w) && !_stopwords.contains(w)) {
        features.add(w);
      }
    }
    for (final w in asciiWords) {
      if (!_unigramOnlyStopwords.contains(w) &&
          !_ambiguousAsciiUnigrams.contains(w)) {
        features.add(w);
      }
    }
    return features;
  }

  /// Load the pre-trained JSON model exported by `ml_training/train_and_export.py`.
  static Future<Map<String, dynamic>?> _loadPretrainedModel() async {
    if (_pretrainedModel != null) return _pretrainedModel;
    if (_modelLoadAttempted) return null;
    _modelLoadAttempted = true;

    // 1. Try local filesystem first (fast in CLI unit tests & desktop dev; skip on Chrome Web)
    if (!kIsWeb) {
      for (final candidatePath in const [
        'assets/models/expense_classifier_model.json',
        'repo/assets/models/expense_classifier_model.json',
      ]) {
        try {
          final file = File(candidatePath);
          if (await file.exists()) {
            final content = await file.readAsString();
            _pretrainedModel = jsonDecode(content) as Map<String, dynamic>;
            return _pretrainedModel;
          }
        } catch (_) {}
      }
    }

    // 2. Load from Flutter asset bundle on Android/iOS/Web
    try {
      final content = await rootBundle
          .loadString('assets/models/expense_classifier_model.json');
      _pretrainedModel = jsonDecode(content) as Map<String, dynamic>;
      return _pretrainedModel;
    } catch (_) {
      return null;
    }
  }

  /// Predict category using the pre-trained TF-IDF + Multinomial Naive Bayes model.
  static Future<MapEntry<String, double>?> _predictWithPretrainedModel(
      String text) async {
    final model = await _loadPretrainedModel();
    if (model == null) return null;

    final classes = (model['classes'] as List?)?.cast<String>() ?? const [];
    final classPriors = model['class_priors'] as Map<String, dynamic>?;
    final defaultLogProb = model['default_log_prob'] as Map<String, dynamic>?;
    final idf = model['idf'] as Map<String, dynamic>?;
    final featureLogProbs =
        model['feature_log_probs'] as Map<String, dynamic>?;

    if (classes.isEmpty ||
        classPriors == null ||
        defaultLogProb == null ||
        idf == null ||
        featureLogProbs == null) {
      return null;
    }

    final tokens = extractFeatures(text);
    final knownTokens = tokens.where((t) => idf.containsKey(t)).toList();
    if (knownTokens.isEmpty) return null;

    final normInput = normalize(text);
    final asciiInput = removeDiacritics(normInput);

    final logScores = <String, double>{};
    for (final c in classes) {
      double score = (classPriors[c] as num?)?.toDouble() ?? 0.0;
      final cProbs = featureLogProbs[c] as Map<String, dynamic>? ?? const {};
      final defLp = (defaultLogProb[c] as num?)?.toDouble() ?? -10.0;
      for (final t in knownTokens) {
        final lp = (cProbs[t] as num?)?.toDouble() ?? defLp;
        final idfWeight = (idf[t] as num?)?.toDouble() ?? 1.0;
        score += lp * idfWeight;
      }
      // Kết hợp Bayesian Domain Prior khi xuất hiện thương hiệu / từ khóa neo đặc trưng
      final brandAnchors = keywords[c];
      if (brandAnchors != null &&
          brandAnchors.any((kw) =>
              normInput.contains(kw) ||
              asciiInput.contains(removeDiacritics(kw)))) {
        score += 4.0;
      }
      logScores[c] = score;
    }

    final maxLog = logScores.values.reduce(math.max);
    final expScores = <String, double>{};
    double sumExp = 0.0;
    for (final entry in logScores.entries) {
      final e = math.exp(entry.value - maxLog);
      expScores[entry.key] = e;
      sumExp += e;
    }

    String? bestClass;
    double bestProb = 0.0;
    for (final entry in expScores.entries) {
      final prob = sumExp > 0 ? entry.value / sumExp : 0.0;
      if (prob > bestProb) {
        bestProb = prob;
        bestClass = entry.key;
      }
    }

    if (bestClass == null) return null;
    return MapEntry(bestClass, bestProb);
  }

  /// [history] is injectable for deterministic tests; production reads SQLite.
  static Future<int?> suggestCategory(
    String text,
    List<GroupModel> groups, {
    List<Map<String, dynamic>>? history,
  }) async {
    final prediction = await predictWithConfidence(
      text,
      groups,
      history: history,
    );
    return prediction?.groupId;
  }

  /// Full ML prediction returning category ID, name, confidence [0..1], and model source.
  static Future<CategoryPrediction?> predictWithConfidence(
    String text,
    List<GroupModel> groups, {
    List<Map<String, dynamic>>? history,
  }) async {
    final input = normalize(text);
    if (input.isEmpty) return null;
    final available = {
      for (final g in groups.where((g) => g.type == 'expense')) g.id: g
    };
    if (available.isEmpty) return null;

    // =========================================================================
    // LAYER 1: Personal SQLite Online Learning (User Habit N-gram & Naive Bayes)
    // =========================================================================
    final rows = history ??
        await (await DatabaseHelper.instance.database).query(
          'transactions_table',
          columns: ['note', 'groupId'],
          // Chỉ học từ nhãn đáng tin cậy:
          // - Người dùng tự chọn tay (user_manual, quick_chip)
          // - Gợi ý ML được xác nhận (ml_suggested_accepted)
          // - Giao dịch cũ chưa có nguồn gốc (NULL → xem như user_manual)
          // KHÔNG học từ ml_suggested_ignored (người dùng đã từ chối gợi ý ML)
          where: "type = ? "
              "AND (isDeleted = 0 OR isDeleted IS NULL) "
              "AND (categorySource IS NULL "
              "  OR categorySource = 'user_manual' "
              "  OR categorySource = 'ml_suggested_accepted' "
              "  OR categorySource = 'quick_chip')",
          whereArgs: ['expense'],
        );

    final votes = <int, double>{};
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
          ? 6.0
          : (note.contains(input) || input.contains(note))
              ? 3.0
              : overlap.toDouble();
      if (score > 0) votes[id] = (votes[id] ?? 0) + score;
    }

    if (votes.isNotEmpty) {
      final ranked = votes.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final bestId = ranked.first.key;
      final totalVotes = votes.values.fold<double>(0.0, (a, b) => a + b);
      final confidence =
          totalVotes > 0 ? (ranked.first.value / totalVotes).clamp(0.5, 0.99) : 0.85;
      return CategoryPrediction(
        groupId: bestId,
        groupName: available[bestId]?.name ?? '',
        confidence: confidence,
        source: 'personal_history_nb',
      );
    }

    // =========================================================================
    // LAYER 2: Pre-trained TF-IDF + Multinomial Naive Bayes Model (JSON Asset)
    // =========================================================================
    final pretrainedResult = await _predictWithPretrainedModel(input);
    if (pretrainedResult != null && pretrainedResult.value >= 0.58) {
      final predictedCategoryNorm = normalize(pretrainedResult.key);
      for (final group in available.values) {
        if (normalize(group.name ?? '') == predictedCategoryNorm) {
          return CategoryPrediction(
            groupId: group.id,
            groupName: group.name ?? pretrainedResult.key,
            confidence: pretrainedResult.value,
            source: 'pretrained_tfidf_nb',
          );
        }
      }
      // If the predicted category is not in `available` (e.g. 'Tiền điện' when
      // user only has ['Ăn uống', 'Di chuyển', 'Mua sắm']), do NOT force a wrong category.
      return null;
    }

    // =========================================================================
    // LAYER 3: Vietnamese Intent Keyword Dictionary Prior
    // =========================================================================
    final inputAscii = removeDiacritics(input);
    for (final entry in keywords.entries) {
      if (entry.value.any((word) =>
          input.contains(word) || inputAscii.contains(removeDiacritics(word)))) {
        for (final group in available.values) {
          if (normalize(group.name ?? '') == normalize(entry.key)) {
            return CategoryPrediction(
              groupId: group.id,
              groupName: group.name ?? entry.key,
              confidence: 0.75,
              source: 'keyword_prior',
            );
          }
        }
      }
    }
    return null;
  }
}
