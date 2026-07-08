/// Hot-path move/scroll frame sender (PAD-05, D-03 raw 1:1 passthrough).
///
/// pointer delta -> `remote_protocol.encodeMove` -> `sink.add`, fire-and-forget.
/// NEVER re-implement the encoder here: the codec in `remote_protocol` is
/// fixture-proven byte-identical to the Rust strict decoder (T-02-CT).
///
/// No await, no buffering, no batching — batching adds latency and queued
/// deltas teleport the cursor on reconnect (RESEARCH Anti-Patterns / spec §8).
/// The trackpad screen (Plan 03) calls this straight from `PointerMove`
/// events with zero widget rebuilds on the path.
library;

import 'dart:async';

import 'package:remote_protocol/remote_protocol.dart';

/// Thin utility over a WebSocket sink (the `IOWebSocketChannel.sink` from
/// `connection_service.dart`) that emits 9-byte binary mouse frames.
class MoveSender {
  /// The WebSocket sink binary frames are added to.
  final StreamSink<dynamic> sink;

  /// Creates a sender writing to [sink].
  MoveSender(this.sink);

  /// Encodes a relative cursor move and adds it to the sink, fire-and-forget.
  ///
  /// A zero delta is still forwarded — the trackpad, not the sender, decides
  /// whether to emit (the sender is a pure pass-through).
  void sendMove(double dx, double dy) {
    sink.add(encodeMove(dx, dy));
  }

  /// Encodes a relative scroll and adds it to the sink, fire-and-forget.
  void sendScroll(double dx, double dy) {
    sink.add(encodeScroll(dx, dy));
  }
}
