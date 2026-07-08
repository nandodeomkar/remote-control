// App-shell smoke test: the scaffold builds and the remote_protocol path
// dependency resolves and imports (Plan 02-02 Task 1 done criterion).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/main.dart';

void main() {
  testWidgets('app shell builds', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: RemoteControlApp()));
    expect(find.text('Remote Control — cursor spike'), findsOneWidget);
  });

  test('remote_protocol imports via path dependency', () {
    // Codec is fixture-proven in the package itself; this only asserts the
    // path-dep import surface is reachable from the app.
    expect(encodeMove(1.0, -2.0).length, 9);
  });
}
