// Task 3 (07-09) — keep-awake ref-count (D-14 / Pitfall 8). Proves the
// wrapper enables the wakelock only on the 0->1 transition and disables only
// on the final 1->0, so the new quick-bar nav path
// (Presenter -> Trackpad -> back) can no longer globally drop keep-awake while
// a still-live screen wants it. The WakelockPlus enable/disable calls are
// injected as spies, so the ref-count is proven WITHOUT the platform channel.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/widgets/keep_awake.dart';

void main() {
  test('enable fires only on 0->1 (second acquire does not re-enable)', () {
    var enables = 0;
    var disables = 0;
    final keep = KeepAwake(
      enable: () async => enables++,
      disable: () async => disables++,
    );

    keep.acquire();
    keep.acquire();

    expect(enables, 1);
    expect(disables, 0);
    expect(keep.activeCount, 2);
  });

  test('disable fires only on the final 1->0 release', () {
    var enables = 0;
    var disables = 0;
    final keep = KeepAwake(
      enable: () async => enables++,
      disable: () async => disables++,
    );

    keep.acquire();
    keep.acquire();
    keep.release(); // 2 -> 1: still wanted, no disable
    expect(disables, 0);
    expect(keep.activeCount, 1);

    keep.release(); // 1 -> 0: last requester gone, disable
    expect(disables, 1);
    expect(keep.activeCount, 0);
  });

  test('release at count 0 is a no-op (no disable, never negative)', () {
    var enables = 0;
    var disables = 0;
    final keep = KeepAwake(
      enable: () async => enables++,
      disable: () async => disables++,
    );

    keep.release();

    expect(disables, 0);
    expect(keep.activeCount, 0);
  });

  test('a fresh acquire after full release re-enables (cycle)', () {
    var enables = 0;
    var disables = 0;
    final keep = KeepAwake(
      enable: () async => enables++,
      disable: () async => disables++,
    );

    keep.acquire(); // 0 -> 1: enable
    keep.release(); // 1 -> 0: disable
    keep.acquire(); // 0 -> 1: enable again

    expect(enables, 2);
    expect(disables, 1);
    expect(keep.activeCount, 1);
  });
}
