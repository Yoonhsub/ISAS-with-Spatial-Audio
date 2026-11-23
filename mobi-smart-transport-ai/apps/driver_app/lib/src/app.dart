import 'package:flutter/material.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'pages/home_page.dart';

const mobiInk = Color(0xFF111111);
const mobiSurface = Colors.white;

ThemeData driverTheme() {
  const panel = Color(0xFFF1F1F1);
  final scheme = ColorScheme.fromSeed(
    seedColor: mobiInk,
    dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
  ).copyWith(
    primary: mobiInk,
    onPrimary: mobiSurface,
    primaryContainer: panel,
    onPrimaryContainer: mobiInk,
    secondary: mobiInk,
    onSecondary: mobiSurface,
    secondaryContainer: panel,
    onSecondaryContainer: mobiInk,
    tertiary: mobiInk,
    onTertiary: mobiSurface,
    tertiaryContainer: panel,
    onTertiaryContainer: mobiInk,
    error: mobiInk,
    onError: mobiSurface,
    errorContainer: panel,
    onErrorContainer: mobiInk,
    surface: mobiSurface,
    onSurface: mobiInk,
    onSurfaceVariant: mobiInk,
    surfaceContainer: mobiSurface,
    surfaceContainerLow: mobiSurface,
    surfaceContainerHigh: panel,
    surfaceContainerHighest: panel,
    outline: mobiInk,
    outlineVariant: const Color(0xFF595959),
    surfaceTint: Colors.transparent,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  return base.copyWith(
    scaffoldBackgroundColor: mobiSurface,
    appBarTheme: const AppBarTheme(
      backgroundColor: mobiSurface,
      foregroundColor: mobiInk,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: mobiSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: mobiInk, width: 2),
        borderRadius: BorderRadius.circular(20),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: mobiInk,
        foregroundColor: mobiSurface,
        minimumSize: const Size(48, 56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: mobiInk,
        foregroundColor: mobiSurface,
        minimumSize: const Size(48, 56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: mobiSurface,
        foregroundColor: mobiInk,
        side: const BorderSide(color: mobiInk, width: 2),
        minimumSize: const Size(48, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ).copyWith(
        side: WidgetStateProperty.resolveWith((states) {
          return BorderSide(
            color: states.contains(WidgetState.disabled)
                ? const Color(0xFF767676)
                : mobiInk,
            width: 2,
          );
        }),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: mobiInk,
        minimumSize: const Size(48, 48),
      ),
    ),
    textTheme: base.textTheme
        .apply(bodyColor: mobiInk, displayColor: mobiInk)
        .copyWith(
          headlineMedium: base.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: mobiInk,
            height: 1.4,
          ),
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: mobiInk,
          ),
        ),
  );
}

class MobiApp extends StatelessWidget {
  const MobiApp(
      {super.key,
      this.firebaseConfigured = false,
      this.authSession,
      this.authOnly = const AuthOnlyConfiguration.fromEnvironment()});

  final bool firebaseConfigured;
  final AuthSession? authSession;
  final AuthOnlyConfiguration authOnly;

  @override
  Widget build(BuildContext context) {
    if (authOnly.enabled) {
      return AuthOnlyApp(
          configurationReady: firebaseConfigured,
          configuration: authOnly,
          requiredRole: 'driver',
          appLabel: 'MOBI_Finals 기사',
          session: authSession);
    }
    return MaterialApp(
      title: 'MOBI_Finals 기사',
      theme: driverTheme(),
      home: AuthGate(
        configurationReady: firebaseConfigured,
        requiredRole: 'driver',
        session: authSession,
        appLabel: 'MOBI_Finals 기사',
        builder: (context, account) =>
            HomePage(key: ValueKey(account.uid), session: authSession),
      ),
    );
  }
}
