import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/core_read.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The delta read is the app's whole claim on incremental sync, and the server
/// contract is narrow: `after_row_id` is exclusive, oldest-first, and a cursor
/// read cannot carry `include_compacted` (400 invalid_pagination). These tests
/// pin the request shape and the two answers the caller branches on: a server
/// that honours the cursor, and one that ignores it.
void main() {
  ApiClient client(
    List<http.Request> seen,
    http.Response Function(http.Request request) answer,
  ) => ApiClient(
    baseUrl: 'http://127.0.0.1:8642',
    apiKey: 'test',
    connectionId: 'connection-a',
    httpClient: MockClient((request) async {
      seen.add(request);
      return answer(request);
    }),
  );

  Map<String, dynamic> row(int id, String content) => {
    'row_id': id,
    'role': 'user',
    'content': content,
  };

  test('a delta read asks for rows after the cursor and never for '
      'compacted generations', () async {
    final seen = <http.Request>[];
    final api = client(
      seen,
      (_) => http.Response(
        jsonEncode({
          'session_id': 'session-a',
          'messages': [row(43, 'newer')],
          'pagination': {'after_row_id': 42, 'returned': 1},
        }),
        200,
      ),
    );

    final delta = await api.getMessagesAfter(
      'session-a',
      afterRowId: 42,
      limit: 120,
    );

    final query = seen.single.url.queryParameters;
    expect(query['after_row_id'], '42');
    expect(query['order'], 'oldest');
    expect(query['limit'], '120');
    expect(query['include_reasoning'], 'false');
    expect(query.containsKey('include_compacted'), isFalse);
    expect(query.containsKey('offset'), isFalse);
    expect(delta.supported, isTrue);
    expect(delta.isEmpty, isFalse);
    expect(delta.nextAfterRowId, 43);
  });

  test('a server that ignores the cursor is detected, not trusted', () async {
    final seen = <http.Request>[];
    final api = client(
      seen,
      (_) => http.Response(
        jsonEncode({
          'session_id': 'session-a',
          // The oldest page from zero: no echo, and nothing above the cursor.
          'messages': [row(1, 'old'), row(2, 'older still')],
          'pagination': {'returned': 2},
        }),
        200,
      ),
    );

    final delta = await api.getMessagesAfter('session-a', afterRowId: 42);

    expect(delta.supported, isFalse);
    expect(delta.nextAfterRowId, 2);
  });

  test('an empty page keeps the cursor so a caller cannot loop', () async {
    final seen = <http.Request>[];
    final api = client(
      seen,
      (_) => http.Response(
        jsonEncode({
          'session_id': 'session-a',
          'messages': const [],
          'pagination': {'after_row_id': 42, 'returned': 0},
        }),
        200,
      ),
    );

    final delta = await api.getMessagesAfter('session-a', afterRowId: 42);

    expect(delta.isEmpty, isTrue);
    expect(delta.supported, isTrue);
    expect(delta.nextAfterRowId, 42);
  });

  test('a rotated transcript is visible to the caller', () async {
    final seen = <http.Request>[];
    final api = client(
      seen,
      (_) => http.Response(
        jsonEncode({
          // A compression rotation continues the session under a child id.
          'session_id': 'session-a-child',
          'messages': [row(9, 'child row')],
          'pagination': {'after_row_id': 42, 'returned': 1},
        }),
        200,
      ),
    );

    final delta = await api.getMessagesAfter('session-a', afterRowId: 42);

    expect(delta.resolvedSessionId, 'session-a-child');
    expect(delta.rotatedFrom('session-a'), isTrue);
    expect(delta.rotatedFrom('session-a-child'), isFalse);
  });

  test('a session that does not echo its id is not treated as rotated', () async {
    final seen = <http.Request>[];
    final api = client(
      seen,
      (_) => http.Response(
        jsonEncode({
          'messages': [row(43, 'newer')],
          'pagination': {'after_row_id': 42, 'returned': 1},
        }),
        200,
      ),
    );

    final delta = await api.getMessagesAfter('session-a', afterRowId: 42);

    expect(delta.resolvedSessionId, isNull);
    expect(delta.rotatedFrom('session-a'), isFalse);
  });

  test('a negative cursor is refused before it reaches the wire', () async {
    final seen = <http.Request>[];
    final api = client(
      seen,
      (_) => http.Response(jsonEncode({'detail': 'invalid_cursor'}), 400),
    );

    await expectLater(
      api.getMessagesAfter('session-a', afterRowId: -1),
      throwsA(isA<CoreReadException>()),
    );
    expect(seen, isEmpty);
  });
}
