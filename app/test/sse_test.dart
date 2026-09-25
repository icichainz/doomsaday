import 'dart:async';
import 'dart:convert';

import 'package:doomsaday/data/sse.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the SSE line parser', () {
    test('reads one simple frame', () {
      final List<SseEvent> events = parseSseFragments(<String>[
        'event: log\ndata: hello\n\n',
      ]);
      expect(events, hasLength(1));
      expect(events.single.event, 'log');
      expect(events.single.data, 'hello');
    });

    test('joins multi-line data with newlines', () {
      final List<SseEvent> events = parseSseFragments(<String>[
        'event: stats\ndata: {"a":1,\ndata: "b":2}\n\n',
      ]);
      expect(events.single.data, '{"a":1,\n"b":2}');
      expect(jsonDecode(events.single.data), <String, Object?>{'a': 1, 'b': 2});
    });

    test('drops comments and keep-alives without dispatching', () {
      final List<SseEvent> events = parseSseFragments(<String>[
        ': keep-alive\n\n',
        ':\n',
        'event: log\ndata: after\n\n',
      ]);
      expect(events, hasLength(1));
      expect(events.single.data, 'after');
    });

    test('survives any chunk boundary, including inside a field name', () {
      const String stream =
          'id: 1\nevent: log\ndata: first\n\n'
          'id: 2\nevent: log\ndata: second\n\n';
      for (int split = 1; split < stream.length; split++) {
        final List<SseEvent> events = parseSseFragments(<String>[
          stream.substring(0, split),
          stream.substring(split),
        ]);
        expect(events.map((SseEvent e) => e.data), <String>[
          'first',
          'second',
        ], reason: 'split at $split');
        expect(events.first.id, '1');
      }
    });

    test('handles CRLF terminators, including a split CRLF', () {
      final List<SseEvent> events = parseSseFragments(<String>[
        'event: log\r\ndata: one\r',
        '\n\r\n',
      ]);
      expect(events.single.data, 'one');
    });

    test('a frame with no event name is a message', () {
      final List<SseEvent> events = parseSseFragments(<String>['data: x\n\n']);
      expect(events.single.event, 'message');
    });

    test('a field with no colon is accepted and ignored', () {
      final List<SseEvent> events = parseSseFragments(<String>[
        'retry\nevent: log\ndata: y\n\n',
      ]);
      expect(events.single.data, 'y');
    });

    test('an unterminated last frame is still dispatched on close', () {
      final List<SseEvent> events = parseSseFragments(<String>[
        'event: done\ndata: last',
      ]);
      expect(events.single.event, 'done');
      expect(events.single.data, 'last');
    });

    test(
      'one leading space after the colon is stripped, further ones kept',
      () {
        final List<SseEvent> events = parseSseFragments(<String>[
          'data:  two spaces\n\n',
        ]);
        expect(events.single.data, ' two spaces');
      },
    );
  });

  group('decodeSse over bytes', () {
    test('decodes a byte stream split mid UTF-8 sequence', () async {
      final List<int> bytes = utf8.encode(
        'event: log\ndata: héllo ✓\n\nevent: log\ndata: two\n\n',
      );
      final StreamController<List<int>> chunks = StreamController<List<int>>();
      final Future<List<SseEvent>> collected = decodeSse(
        chunks.stream,
      ).toList();
      for (int i = 0; i < bytes.length; i += 3) {
        chunks.add(bytes.sublist(i, (i + 3).clamp(0, bytes.length)));
      }
      await chunks.close();

      final List<SseEvent> events = await collected;
      expect(events.map((SseEvent e) => e.data), <String>['héllo ✓', 'two']);
    });

    test('cancelling the subscription stops reading the source', () async {
      bool cancelled = false;
      final StreamController<List<int>> chunks = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final StreamSubscription<SseEvent> subscription = decodeSse(
        chunks.stream,
      ).listen((_) {});
      chunks.add(utf8.encode('event: log\ndata: a\n\n'));
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      expect(cancelled, isTrue);
      await chunks.close();
    });
  });
}
