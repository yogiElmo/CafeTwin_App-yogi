import 'package:cafetwin_app/screens/login_screen.dart';
import 'package:cafetwin_app/state/cafe_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // This test build sets neither --dart-define=API_BASE_URL nor any
  // DEMO_* value, so ApiService.isEnabled and AuthService.hasDemoFallback
  // are both false. That means AuthService.restoreSession() and
  // AuthService.login() both return synchronously without ever touching
  // flutter_secure_storage, so these tests exercise the real login screen
  // without needing to mock any platform channel.

  testWidgets(
    'shows a clear error when no backend and no demo credentials are '
    'configured, instead of accepting anything',
    (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: LoginScreen(state: CafeState()),
      ));
      // initState() kicks off _tryRestoreSession(); let it settle so the
      // login form (not the loading spinner) is what we interact with.
      await tester.pumpAndSettle();

      final Finder loginButton = find.widgetWithText(ElevatedButton, 'Login');
      expect(loginButton, findsOneWidget);

      await tester.tap(loginButton);
      await tester.pumpAndSettle();

      expect(find.textContaining('No backend is configured'), findsOneWidget);
      // Still on the login screen -- no navigation happened on failure.
      expect(find.byType(LoginScreen), findsOneWidget);
    },
  );

  testWidgets(
    'does not show the offline-demo hint when no demo credentials are '
    'configured',
    (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: LoginScreen(state: CafeState()),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('Offline demo mode'), findsNothing);
    },
  );

  testWidgets('renders the three credential fields and no hardcoded values',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(state: CafeState()),
    ));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Username'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
    expect(
        find.widgetWithText(TextField, 'Authentication PIN'), findsOneWidget);

    // Every field starts empty -- nothing is pre-filled for the admin.
    final Iterable<TextField> fields =
        tester.widgetList<TextField>(find.byType(TextField));
    for (final TextField field in fields) {
      expect(field.controller!.text, isEmpty);
    }
  });
}
