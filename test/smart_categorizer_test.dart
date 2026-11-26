import 'package:flutter_test/flutter_test.dart';
import 'package:onemorecoin/model/GroupModel.dart';
import 'package:onemorecoin/services/SmartCategorizerService.dart';

void main() {
  final groups = [
    GroupModel(1, 1, name: 'Ăn uống', type: 'expense'),
    GroupModel(2, 1, name: 'Di chuyển', type: 'expense'),
    GroupModel(3, 1, name: 'Mua sắm', type: 'expense'),
    GroupModel(12, 1, name: 'Lương', type: 'income'),
  ];
  test('dictionary and pretrained model map to actual expense group', () async {
    expect(
        await SmartCategorizerService.suggestCategory(
            'Highlands Coffee', groups,
            history: []),
        1);
    expect(
        await SmartCategorizerService.suggestCategory('WinMart', groups,
            history: []),
        3);
  });
  test('personal history overrides generic keyword', () async {
    expect(
        await SmartCategorizerService.suggestCategory('Grab', groups, history: [
          {'note': 'Grab', 'groupId': 1}
        ]),
        1);
  });
  test('does not suggest missing or income groups', () async {
    expect(
        await SmartCategorizerService.suggestCategory('EVN', groups,
            history: []),
        isNull);
    expect(
        await SmartCategorizerService.suggestCategory('Lương', groups,
            history: [
              {'note': 'Lương', 'groupId': 12}
            ]),
        isNull);
  });
  test('pretrained TF-IDF Naive Bayes model predicts with confidence on unaccented OCR text', () async {
    final fullGroups = [
      ...groups,
      GroupModel(4, 1, name: 'Sức khỏe', type: 'expense'),
      GroupModel(5, 1, name: 'Tiền điện', type: 'expense'),
    ];
    final pred1 = await SmartCategorizerService.predictWithConfidence(
      'Nha Thuoc Long Chau mua vitamin',
      fullGroups,
      history: [],
    );
    expect(pred1, isNotNull);
    expect(pred1!.groupId, 4);
    expect(pred1.source, 'pretrained_tfidf_nb');
    expect(pred1.confidence, greaterThan(0.5));

    final pred2 = await SmartCategorizerService.predictWithConfidence(
      'EVNHCMC thanh toan hoa don tien dien',
      fullGroups,
      history: [],
    );
    expect(pred2, isNotNull);
    expect(pred2!.groupId, 5);
  });
}
