import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pia_wireguard_cfga/main.dart';

import 'http_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MainScreen widget integration', () {
    testWidgets('region picker loads, filters, and selects a region',
        (tester) async {
      await withFakeHttpClient(
        () async {
          await tester.pumpWidget(const PiaWgApp());
          await tester.pumpAndSettle();

          await tester.tap(find.byIcon(Icons.list_alt));
          await tester.pumpAndSettle();

          expect(find.text('aus_melbourne'), findsOneWidget);
          await tester.enterText(find.byType(TextField).first, 'melbourne');
          await tester.pumpAndSettle();

          expect(find.text('aus_melbourne'), findsOneWidget);
          await tester.tap(find.text('aus_melbourne'));
          await tester.pumpAndSettle();

          expect(find.widgetWithText(TextFormField, 'aus_melbourne'),
              findsOneWidget);
        },
        (url, method) {
          if (url.toString().contains('vpninfo/servers/v6')) {
            return FakeHttpClientResponse(
                200,
                '${jsonEncode({
                      'regions': [
                        {
                          'id': 'aus_melbourne',
                          'servers': {
                            'wg': [
                              {'ip': '1.2.3.4', 'cn': 'aus'}
                            ]
                          }
                        }
                      ]
                    })}\n');
          }
          return FakeHttpClientResponse(404, 'not found');
        },
      );
    });

    testWidgets('empty credentials show validation error and clear log works',
        (tester) async {
      await tester.pumpWidget(const PiaWgApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('GENERATE CONFIG'));
      await tester.pumpAndSettle();

      expect(find.text('Region, username, and password required.'),
          findsOneWidget);
      expect(find.text('CLEAR LOG'), findsOneWidget);

      await tester.tap(find.text('CLEAR LOG'));
      await tester.pumpAndSettle();

      expect(find.text('Ready.'), findsOneWidget);
    });

    testWidgets('main screen shows form fields and generate button',
        (tester) async {
      await tester.pumpWidget(const PiaWgApp());
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextFormField, 'Region ID'), findsOneWidget);
      expect(
          find.widgetWithText(TextFormField, 'PIA username'), findsOneWidget);
      expect(
          find.widgetWithText(TextFormField, 'PIA password'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'DNS servers'), findsOneWidget);
      expect(find.text('GENERATE CONFIG'), findsOneWidget);
    });
  });
}
