import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

/// The exact wire contract the app parses for turn identity.
///
/// These shapes are what the gateway has to emit for
/// `submitPromptIdempotent` and `getTurnStatus` to return instead of throwing.
/// They are pinned here so a server-side change and an app-side change cannot
/// drift apart silently: today's `prompt.submit` answers `{"status":
/// "streaming"}`, which this parser rejects, which is why the turn-identity
/// protocol has to be added server-side before either side can rely on it.
void main() {
  group('prompt.submit acknowledgement', () {
    Map<String, dynamic> ack({
      Object? clientTurnId = 'turn-1',
      Object? serverTurnId = 'server-turn-1',
      Object? state = 'accepted',
      Object? duplicate = false,
      Object? accepted = true,
    }) => {
      'accepted': accepted,
      'client_turn_id': clientTurnId,
      'server_turn_id': serverTurnId,
      'state': state,
      'duplicate': duplicate,
      // Additive fields the server will send once it owns a turn registry.
      // The parser must ignore them rather than choke, so a server can ship
      // them before the app reads them.
      'idempotent': true,
      'replayed': false,
    };

    test('the accepted shape parses, and additive flags do not break it', () {
      final parsed = DesktopTurnAck.fromJson(
        ack(),
        expectedClientTurnId: 'turn-1',
      );

      expect(parsed.accepted, isTrue);
      expect(parsed.clientTurnId, 'turn-1');
      expect(parsed.serverTurnId, 'server-turn-1');
      expect(parsed.state, DesktopTurnState.accepted);
      expect(parsed.duplicate, isFalse);
    });

    test('a replayed ack is the same shape with the flags flipped', () {
      final parsed = DesktopTurnAck.fromJson({
        ...ack(),
        'duplicate': true,
        'replayed': true,
        'state': 'terminal',
      }, expectedClientTurnId: 'turn-1');

      expect(parsed.duplicate, isTrue);
      expect(parsed.state, DesktopTurnState.terminal);
    });

    test("today's server answer is rejected, which is the gap", () {
      expect(
        () => DesktopTurnAck.fromJson({
          'status': 'streaming',
        }, expectedClientTurnId: 'turn-1'),
        throwsA(isA<TuiGatewayRpcError>()),
      );
    });

    test('a missing echo, server id, state or duplicate is rejected', () {
      for (final broken in [
        ack(clientTurnId: 'someone-else'),
        ack(serverTurnId: ''),
        ack(state: 'whatever'),
        ack(duplicate: null),
        ack(accepted: false),
        ack(state: 'failed'),
      ]) {
        expect(
          () => DesktopTurnAck.fromJson(broken, expectedClientTurnId: 'turn-1'),
          throwsA(isA<TuiGatewayRpcError>()),
        );
      }
    });
  });

  group('turn.status answer', () {
    test('a known turn parses', () {
      final status = DesktopTurnStatus.fromJson({
        'known': true,
        'client_turn_id': 'turn-1',
        'server_turn_id': 'server-turn-1',
        'state': 'running',
      }, expectedClientTurnId: 'turn-1');

      expect(status.known, isTrue);
      expect(status.state, DesktopTurnState.running);
      expect(status.serverTurnId, 'server-turn-1');
    });

    test('an unknown turn parses, but only with the id echoed', () {
      final status = DesktopTurnStatus.fromJson({
        'known': false,
        'client_turn_id': 'turn-1',
      }, expectedClientTurnId: 'turn-1');

      expect(status.known, isFalse);
      expect(status.state, isNull);

      expect(
        () => DesktopTurnStatus.fromJson({
          'known': false,
        }, expectedClientTurnId: 'turn-1'),
        throwsA(isA<TuiGatewayRpcError>()),
      );
    });

    test('a known turn without a server id is rejected', () {
      expect(
        () => DesktopTurnStatus.fromJson({
          'known': true,
          'client_turn_id': 'turn-1',
          'state': 'accepted',
        }, expectedClientTurnId: 'turn-1'),
        throwsA(isA<TuiGatewayRpcError>()),
      );
    });
  });
}
