import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pia_wireguard_cfga/main.dart';

void main() {
  testWidgets('shows PIA WireGuard config form', (tester) async {
    await tester.pumpWidget(const PiaWgApp());
    await tester.pumpAndSettle();

    expect(find.text('PIA WireGuard Config'), findsOneWidget);
    expect(find.text('Region ID'), findsOneWidget);
    expect(find.text('PIA username'), findsOneWidget);
    expect(find.text('PIA password'), findsOneWidget);
    expect(find.text('DNS servers'), findsOneWidget);
    expect(find.text('GENERATE CONFIG'), findsOneWidget);
    expect(find.byIcon(Icons.list_alt), findsOneWidget);
  });
}
