import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Punto de reanudación durable de una sesión: la última fila que ESTE
/// dispositivo ya publicó en pantalla.
///
/// La app releía la ventana más reciente (y a veces el transcript entero) en
/// cada apertura y en cada reconexión. Con este marcador la siguiente lectura
/// pide solo lo que es más nuevo (`order=oldest&after_row_id=`), que es lo único
/// que un offset medido hacia atrás desde la punta no puede expresar sin que un
/// mensaje recién llegado desplace la ventana.
///
/// Es una coordenada de caché, nunca una autoridad: si el cursor no coincide con
/// la fila más nueva que la proyección local conserva, se ignora y se vuelve a
/// la lectura de cola normal. Por eso una sesión borrada o recreada no puede
/// heredar un cursor viejo: sin transcript local no hay cursor utilizable.
@immutable
final class TranscriptCursor {
  const TranscriptCursor({
    required this.rowId,
    required this.tipRowId,
    required this.messageCount,
    required this.updatedAtMs,
  });

  static const int formatVersion = 1;

  /// Fila durable (`row_id`) más nueva que el dispositivo ya mostró. La
  /// siguiente lectura pide `row_id > rowId`.
  final int rowId;

  /// Punta que el servidor anunció al escribir este cursor, si la hubo. Sirve
  /// para detectar que el servidor retrocedió (rewind/compaction in-place) y el
  /// cursor ya no describe la misma línea temporal.
  final int? tipRowId;

  /// Cuántas filas componían la ventana publicada. Solo se usa como evidencia
  /// de que el cursor se escribió desde una página real, no desde un vacío.
  final int messageCount;

  final int updatedAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'v': formatVersion,
    'row_id': rowId,
    'tip_row_id': tipRowId,
    'count': messageCount,
    'at': updatedAtMs,
  };

  /// `null` cuando el registro no tiene la forma esperada: un cursor corrupto
  /// no puede degradar la lectura, solo perderse.
  static TranscriptCursor? fromJson(Object? raw) {
    if (raw is! Map) return null;
    if (raw['v'] != formatVersion) return null;
    final rowId = _positiveInt(raw['row_id']);
    if (rowId == null) return null;
    final count = raw['count'];
    final at = raw['at'];
    return TranscriptCursor(
      rowId: rowId,
      tipRowId: _positiveInt(raw['tip_row_id']),
      messageCount: count is int && count >= 0 ? count : 0,
      updatedAtMs: at is int && at >= 0 ? at : 0,
    );
  }

  static int? _positiveInt(Object? value) {
    if (value is int) return value > 0 ? value : null;
    if (value is String) {
      final parsed = int.tryParse(value);
      return parsed != null && parsed > 0 ? parsed : null;
    }
    return null;
  }
}

/// Persistencia del [TranscriptCursor] por conexión + perfil + sesión.
///
/// Usa el mismo ámbito (`_scope`) y la misma clave canónica de perfil que
/// `LocalTranscriptStore`, y el mismo almacén cifrado, para que borrar una
/// conversación local y borrar su cursor sean la misma operación de facto.
final class TranscriptCursorStore {
  static const _storage = FlutterSecureStorage();
  static const _prefix = 'hermes.cursor.v1.';

  static String _canonicalProfile(String? profile) =>
      profile == null || profile.isEmpty ? 'default' : profile;

  static String _scope(String value) => value.codeUnits
      .map((unit) => unit.toRadixString(16).padLeft(4, '0'))
      .join();

  static String key(String connId, String sessionId, {String? profile}) =>
      '$_prefix${_scope(connId)}.${_scope(_canonicalProfile(profile))}.'
      '${_scope(sessionId)}';

  static Future<TranscriptCursor?> read(
    String connId,
    String sessionId, {
    String? profile,
  }) async {
    try {
      final raw = await _storage.read(
        key: key(connId, sessionId, profile: profile),
      );
      if (raw == null || raw.isEmpty) return null;
      return TranscriptCursor.fromJson(jsonDecode(raw));
    } catch (_) {
      // Un cursor ilegible solo cuesta una lectura de cola: nunca rompe el chat.
      return null;
    }
  }

  /// Guarda [cursor] si avanza la coordenada. Nunca retrocede: dos lecturas
  /// concurrentes (reconexión + terminal) pueden terminar fuera de orden y la
  /// más lenta no debe devolver el punto de reanudación al pasado.
  static Future<void> write(
    String connId,
    String sessionId, {
    String? profile,
    required TranscriptCursor cursor,
    bool force = false,
  }) async {
    final physicalKey = key(connId, sessionId, profile: profile);
    try {
      if (!force) {
        final previous = await read(connId, sessionId, profile: profile);
        if (previous != null && previous.rowId >= cursor.rowId) return;
      }
      await _storage.write(
        key: physicalKey,
        value: jsonEncode(cursor.toJson()),
      );
    } catch (_) {
      // Perder el cursor solo cuesta bytes en la próxima apertura.
    }
  }

  static Future<void> clear(
    String connId,
    String sessionId, {
    String? profile,
  }) async {
    try {
      await _storage.delete(key: key(connId, sessionId, profile: profile));
    } catch (_) {
      // Nada que reparar: un cursor huérfano se descarta al no coincidir.
    }
  }
}
