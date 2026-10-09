import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onemorecoin/pages/LoginScreen.dart';
import 'package:onemorecoin/utils/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Login screen validates required fields and toggles password',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: LoginScreen()),
    );

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(2));

    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    final label = S
            .of(tester.element(find.byType(LoginScreen)))
            .get('please_enter_username_or_email') ??
        'Vui lòng nhập tên đăng nhập hoặc email';
    expect(find.text(label), findsOneWidget);

    final password = find.byType(EditableText).at(1);
    expect(tester.widget<EditableText>(password).obscureText, isTrue);
    await tester.ensureVisible(find.byIcon(Icons.visibility_off));
    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pump();
    expect(tester.widget<EditableText>(password).obscureText, isFalse);
  });
}
