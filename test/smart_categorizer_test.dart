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
  test('dictionary maps to actual expense group', () async {
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
}
