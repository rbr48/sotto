import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/call/ui/common.dart';

void main() {
  testWidgets('the own-video window can be dragged and snaps to a corner', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                DraggablePreview(
                  area: constraints.biggest,
                  child: const SizedBox.expand(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final preview = find.byKey(const Key('self-preview'));
    // Starts in the bottom right corner.
    expect(
      tester.getTopLeft(preview),
      const Offset(400 - 160 - 16, 800 - 120 - 16),
    );

    // Dragged towards the top left, then let go: it snaps to that corner.
    final gesture = await tester.startGesture(tester.getCenter(preview));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(-15, -50));
      await tester.pump();
    }
    expect(
      tester.getTopLeft(preview),
      const Offset(74, 164),
      reason: 'follows',
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(preview), const Offset(16, 16));

    // A quick flick (one move, then let go) lands where it was flung.
    await tester.drag(preview, const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(preview), const Offset(400 - 160 - 16, 16));
    await tester.drag(preview, const Offset(-300, 0));
    await tester.pumpAndSettle();

    // A short drag stays in the same corner.
    await tester.drag(preview, const Offset(30, 40));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(preview), const Offset(16, 16));
  });
}
