// App-shell smoke test: the trackpad screen builds (placeholder removed in
// 02-03) and the remote_protocol path dependency resolves and imports.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/main.dart';
import 'package:remote_control/trackpad/trackpad_screen.dart';

void main() {
  testWidgets('app shell routes to the trackpad screen', (tester) async {
    await tester.pumpWidget(const RemoteControlApp());
    await tester.pump();

    // The placeholder is gone; the trackpad screen + connect UI are present.
    expect(find.byType(TrackpadScreen), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Remote Control — cursor spike'), findsNothing);
  });

  test('remote_protocol imports via path dependency', () {
    // Codec is fixture-proven in the package itself; this only asserts the
    // path-dep import surface is reachable from the app.
    expect(encodeMove(1.0, -2.0).length, 9);
  });
}
