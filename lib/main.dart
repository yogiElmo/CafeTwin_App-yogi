import 'package:flutter/material.dart';

import 'screens/login_screen.dart';
import 'state/cafe_state.dart';

void main() => runApp(const CafeTwinApp());

/// CaféTwin: gaming café digital twin dashboard.
///
/// Creates a single [CafeState] (unconfigured — the simulation engine only
/// starts after the admin logs in and completes organization setup) and
/// injects it into the widget tree by constructor — no state-management
/// packages.
class CafeTwinApp extends StatefulWidget {
  const CafeTwinApp({super.key});

  @override
  State<CafeTwinApp> createState() => _CafeTwinAppState();
}

class _CafeTwinAppState extends State<CafeTwinApp> {
  final CafeState _state = CafeState();

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  ThemeData _buildTheme() {
    const Color background = Color(0xFF1E1B18); // warm charcoal
    const Color surface = Color(0xFF26221E);
    const Color amber = Color(0xFFD9A441);
    const Color text = Color(0xFFE8E2D8);

    const ColorScheme scheme = ColorScheme.dark(
      primary: amber,
      secondary: amber,
      surface: surface,
      error: Color(0xFFCC5148),
      onPrimary: background,
      onSecondary: background,
      onSurface: text,
      onError: text,
    );

    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      cardColor: surface,
      dividerColor: const Color(0xFF3A332C),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: text,
        elevation: 0,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: amber,
        unselectedItemColor: Color(0xFF8A8178),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CaféTwin',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: LoginScreen(state: _state),
    );
  }
}
