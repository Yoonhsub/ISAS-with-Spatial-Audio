import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/pages/passenger_presentation.dart';

void main() {
  test('passenger theme has white surfaces and dark, readable controls', () {
    final theme = passengerTheme();
    const white = Color(0xFFFFFFFF);
    const ink = Color(0xFF111111);
    const enabled = <WidgetState>{};
    const disabled = <WidgetState>{WidgetState.disabled};

    expect(theme.scaffoldBackgroundColor, white);
    expect(theme.appBarTheme.backgroundColor, white);
    expect(theme.appBarTheme.foregroundColor, ink);
    expect(theme.colorScheme.surface, white);
    expect(theme.colorScheme.onSurface, ink);
    expect(theme.textTheme.bodyMedium?.color, ink);
    expect(theme.textTheme.headlineMedium?.color, ink);
    expect(
      (white.computeLuminance() + 0.05) / (ink.computeLuminance() + 0.05),
      greaterThan(7),
    );

    final filled = theme.filledButtonTheme.style!;
    expect(filled.backgroundColor?.resolve(enabled), ink);
    expect(filled.foregroundColor?.resolve(enabled), white);
    expect(filled.backgroundColor?.resolve(disabled), isNot(ink));
    expect(
      filled.minimumSize?.resolve(enabled)?.shortestSide,
      greaterThanOrEqualTo(48),
    );

    final outlined = theme.outlinedButtonTheme.style!;
    expect(outlined.backgroundColor?.resolve(enabled), white);
    expect(outlined.foregroundColor?.resolve(enabled), ink);
    expect(
      outlined.side?.resolve(enabled),
      const BorderSide(color: ink, width: 2),
    );
    expect(outlined.side?.resolve(disabled)?.color, isNot(ink));
    expect(
      outlined.minimumSize?.resolve(enabled)?.shortestSide,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('home actions have distinct icons and retain labeled semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: passengerTheme(),
        home: PassengerLanding(
          onOnline: () {},
          onSignOut: () {},
          showSignOut: true,
        ),
      ),
    );

    const features = <String, IconData>{
      '노선 정보 검색': Icons.search_rounded,
      '장애물 탐지': Icons.videocam_rounded,
      '테스트': Icons.checklist_rounded,
    };
    for (final feature in features.entries) {
      expect(find.byIcon(feature.value), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byIcon(feature.value),
          matching: find.byType(FilledButton),
        ),
        findsOneWidget,
      );
      final button = find.bySemanticsLabel(feature.key);
      expect(button, findsOneWidget);
      final node = tester.getSemantics(button).getSemanticsData();
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.hint, isNotEmpty);
    }
    expect(find.byIcon(Icons.logout_rounded), findsOneWidget);
    semantics.dispose();
  });
}
