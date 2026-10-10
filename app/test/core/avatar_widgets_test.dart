import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/core/l10n/app_localizations.dart';
import 'package:sotto/core/ui_kit.dart';

/// A real 1 × 1 PNG.
const _onePixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

/// A PNG whose header claims [width] × [height] pixels.
String _claiming(int width, int height) {
  final bytes = base64Decode(_onePixel);
  ByteData.sublistView(bytes)
    ..setUint32(16, width)
    ..setUint32(20, height);
  return 'data:image/png;base64,${base64Encode(bytes)}';
}

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

ImageProvider? _backgroundOf(WidgetTester tester) =>
    tester.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundImage;

void main() {
  setUp(InitialsAvatar.clearCache);

  testWidgets('a picture is decoded once and reused across rebuilds', (
    tester,
  ) async {
    // Two equal strings that are different objects, as after a reload.
    final first = 'data:image/png;base64,$_onePixel';
    final second = ['data:image/png;base64,', _onePixel].join();
    expect(identical(first, second), isFalse);

    await tester.pumpWidget(
      _app(InitialsAvatar(name: 'Meera Rao', avatar: first)),
    );
    final before = _backgroundOf(tester);
    expect(before, isA<ResizeImage>());
    expect(find.text('MR'), findsNothing);

    await tester.pumpWidget(
      _app(InitialsAvatar(name: 'Meera Rao', avatar: second, key: UniqueKey())),
    );
    final after = _backgroundOf(tester);
    // Same bytes object, so the image cache finds the decoded image.
    expect(after, before);
    expect(
      identical(
        (after! as ResizeImage).imageProvider,
        (before! as ResizeImage).imageProvider,
      ),
      isTrue,
    );
    expect(InitialsAvatar.cachedPictures, 1);
  });

  testWidgets('the picture is decoded at the size it is shown', (tester) async {
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(
        InitialsAvatar(
          name: 'Meera Rao',
          avatar: 'data:image/png;base64,$_onePixel',
          radius: 22,
        ),
      ),
    );
    final image = _backgroundOf(tester)! as ResizeImage;
    expect((image.width, image.height), (88, 88));
  });

  testWidgets('pictures that fail the checks show the initials', (
    tester,
  ) async {
    for (final avatar in [
      _claiming(513, 10),
      _claiming(4000, 4000),
      'data:image/jpeg;base64,$_onePixel',
      'data:image/gif;base64,R0lGODlhAQABAAAAACw=',
      _onePixel,
      'data:image/png;base64,not base64!',
    ]) {
      await tester.pumpWidget(
        _app(InitialsAvatar(name: 'Meera Rao', avatar: avatar)),
      );
      expect(_backgroundOf(tester), isNull, reason: avatar);
      expect(find.text('MR'), findsOneWidget, reason: avatar);
    }
  });

  for (final (locale, atEnd) in [
    (const Locale('en'), 'right'),
    (const Locale('ar'), 'left'),
  ]) {
    testWidgets('the camera button is labelled, tappable and on the $atEnd '
        'in ${locale.languageCode}', (tester) async {
      final semantics = tester.ensureSemantics();
      var picked = 0;
      await tester.pumpWidget(
        _app(
          EditableAvatar(name: 'Meera Rao', onPick: () => picked++),
          locale: locale,
        ),
      );
      final l10n = await AppLocalizations.delegate.load(locale);
      final avatar = tester.getRect(find.byType(EditableAvatar));
      final button = tester.getRect(find.byIcon(Icons.photo_camera));
      // Wholly inside the avatar's box, so all of it can be hit.
      expect(avatar.intersect(button), button);
      expect(
        atEnd == 'right'
            ? button.center.dx > avatar.center.dx
            : button.center.dx < avatar.center.dx,
        isTrue,
      );
      expect(find.bySemanticsLabel(l10n.avatarChangePhoto), findsOneWidget);
      expect(find.byTooltip(l10n.avatarChangePhoto), findsOneWidget);

      await tester.tap(find.byIcon(Icons.photo_camera));
      expect(picked, 1);
      semantics.dispose();
    });
  }
}
