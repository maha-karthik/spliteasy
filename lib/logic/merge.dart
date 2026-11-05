// Pure Dart. The rules two phones use to agree on one version of a record, whatever order
// their changes arrive in. Used by the sync stage; no backend is involved here.

/// Version stamp of one synced record.
class Stamp {
  final int updatedAt; // milliseconds since epoch
  final bool deleted; // tombstone: the record was deleted
  final String origin; // id of the device/user that wrote it; only breaks exact ties
  const Stamp(this.updatedAt, {this.deleted = false, this.origin = ''});

  @override
  String toString() => 'Stamp($updatedAt${deleted ? ', deleted' : ''}, $origin)';
}

/// True if [incoming] should replace [current].
/// Last writer wins by time. On the exact same millisecond a delete wins, then the higher
/// [Stamp.origin] wins, so every phone picks the same winner. Identical stamps change nothing.
bool incomingWins(Stamp? current, Stamp incoming) {
  if (current == null) return true;
  if (incoming.updatedAt != current.updatedAt) return incoming.updatedAt > current.updatedAt;
  if (incoming.deleted != current.deleted) return incoming.deleted;
  return incoming.origin.compareTo(current.origin) > 0;
}

/// Remembers which queued operations were already applied, so a retried or replayed
/// operation can never be applied twice.
class AppliedOps {
  final Set<String> _seen = {};

  /// Returns true the first time [opId] is seen, false for every repeat.
  bool firstTime(String opId) => _seen.add(opId);
}
