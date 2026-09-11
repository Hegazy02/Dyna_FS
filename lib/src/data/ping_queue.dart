import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../config/app_config.dart';
import '../models/location_ping.dart';

/// A queued row: the ping plus the id needed to delete it once acknowledged.
class QueuedPing {
  const QueuedPing({required this.id, required this.ping});

  final int id;
  final LocationPing ping;
}

/// Schema history:
///  1. id, payload, recorded_at
///  2. + user_id — see [PingQueue] on why rows are owned.
const int _schemaVersion = 2;

/// Durable FIFO buffer of location fixes waiting to reach the backend.
///
/// Every fix is written here first and only deleted after the server confirms
/// it. That is what makes tunnels, dead zones, and flaky mobile data
/// non-events: the app keeps recording and drains the backlog on reconnect.
///
/// Owned exclusively by the background service isolate — the UI isolate never
/// opens it, which sidesteps cross-isolate SQLite locking entirely.
///
/// Every row records which signed-in user captured it, and uploads only ever
/// drain rows belonging to the user who is signed in right now. Without that,
/// a driver who queues a day of movement offline and then hands the phone over
/// would have their positions uploaded under the next person's account.
class PingQueue {
  PingQueue._(this._db);

  final Database? _db;

  /// Fallback used only if SQLite cannot be opened. Losing durability is bad,
  /// but silently not tracking at all would be worse.
  final List<QueuedPing> _fallback = <QueuedPing>[];
  final Map<int, String> _fallbackOwners = <int, String>{};
  int _fallbackSeq = 0;

  /// Inserts since the last capacity check. Counting rows on every insert
  /// would mean a table scan twice a minute forever, for a cap that can only
  /// be reached after hours offline.
  int _sinceTrimCheck = 0;
  static const int _trimCheckInterval = 50;

  bool get isDurable => _db != null;

  static Future<PingQueue> open() async {
    Database? db;
    try {
      final path = p.join(await getDatabasesPath(), 'dyn_gis_queue.db');
      db = await openDatabase(
        path,
        version: _schemaVersion,
        onCreate: (Database d, int version) async {
          await d.execute('''
            CREATE TABLE pings (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              user_id TEXT NOT NULL DEFAULT '',
              payload TEXT NOT NULL,
              recorded_at INTEGER NOT NULL
            )
          ''');
          await d.execute(
            'CREATE INDEX idx_pings_user ON pings (user_id, id)',
          );
        },
        onUpgrade: (Database d, int from, int to) async {
          if (from < 2) {
            await d.execute(
              "ALTER TABLE pings ADD COLUMN user_id TEXT NOT NULL DEFAULT ''",
            );
            await d.execute(
              'CREATE INDEX IF NOT EXISTS idx_pings_user ON pings (user_id, id)',
            );
          }
        },
      );
    } catch (_) {
      db = null;
    }
    return PingQueue._(db);
  }

  Future<void> enqueue(LocationPing ping, {required String userId}) async {
    final db = _db;
    if (db == null) {
      _fallback.add(
        QueuedPing(id: _fallbackSeq++, ping: ping),
      );
      _fallbackOwners[_fallbackSeq - 1] = userId;
      _trimFallback();
      return;
    }

    await db.insert('pings', <String, Object?>{
      'user_id': userId,
      'payload': ping.encode(),
      'recorded_at': ping.recordedAt.millisecondsSinceEpoch,
    });
    await _trim(db);
  }

  /// Oldest-first batch for one user, left in place until [remove] confirms
  /// delivery.
  Future<List<QueuedPing>> peek(int limit, {required String userId}) async {
    final db = _db;
    if (db == null) {
      return _fallback
          .where((q) => _fallbackOwners[q.id] == userId)
          .take(limit)
          .toList(growable: false);
    }

    final rows = await db.query(
      'pings',
      columns: <String>['id', 'payload'],
      where: 'user_id = ?',
      whereArgs: <Object?>[userId],
      orderBy: 'id ASC',
      limit: limit,
    );

    final result = <QueuedPing>[];
    final corrupt = <int>[];
    for (final row in rows) {
      final id = row['id']! as int;
      try {
        result.add(
          QueuedPing(id: id, ping: LocationPing.decode(row['payload']! as String)),
        );
      } catch (_) {
        // An unparseable row would stall the queue head forever. Bin it.
        corrupt.add(id);
      }
    }
    if (corrupt.isNotEmpty) await remove(corrupt);
    return result;
  }

  Future<void> remove(List<int> ids) async {
    if (ids.isEmpty) return;

    final db = _db;
    if (db == null) {
      _fallback.removeWhere((q) => ids.contains(q.id));
      for (final id in ids) {
        _fallbackOwners.remove(id);
      }
      return;
    }

    final placeholders = List<String>.filled(ids.length, '?').join(',');
    await db.delete('pings', where: 'id IN ($placeholders)', whereArgs: ids);
  }

  /// Total rows, across all users. Used for the capacity check.
  Future<int> length() async {
    final db = _db;
    if (db == null) return _fallback.length;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM pings'),
        ) ??
        0;
  }

  /// Rows waiting for one user — what the diagnostics panel reports, since a
  /// total that includes a previous user's backlog would be misleading.
  Future<int> pendingFor(String userId) async {
    final db = _db;
    if (db == null) {
      return _fallbackOwners.values.where((id) => id == userId).length;
    }
    return Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM pings WHERE user_id = ?',
            <Object?>[userId],
          ),
        ) ??
        0;
  }

  Future<void> close() async => _db?.close();

  /// Drops the oldest rows once the backlog exceeds the configured cap.
  Future<void> _trim(Database db) async {
    if (++_sinceTrimCheck < _trimCheckInterval) return;
    _sinceTrimCheck = 0;

    final count = await length();
    if (count <= AppConfig.queueCapacity) return;

    await db.rawDelete(
      'DELETE FROM pings WHERE id NOT IN '
      '(SELECT id FROM pings ORDER BY id DESC LIMIT ?)',
      <Object?>[AppConfig.queueCapacity],
    );
  }

  void _trimFallback() {
    // The in-memory path is a last resort, so keep it far smaller than the
    // durable cap to avoid pushing the service into an OOM kill.
    const memoryCap = 2000;
    if (_fallback.length > memoryCap) {
      _fallback.removeRange(0, _fallback.length - memoryCap);
    }
  }
}
