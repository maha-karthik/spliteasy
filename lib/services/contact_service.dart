import 'package:system_contact_picker/system_contact_picker.dart';
import '../logic/contact_utils.dart';

class PickedPerson {
  final String name;
  final List<String> phones; // normalised (E.164), valid numbers only, no duplicates
  const PickedPerson(this.name, this.phones);
}

/// Uses Android's own contact picker.
/// - No READ_CONTACTS permission is declared or requested.
/// - The app only ever receives the single contact the user taps, never the address book.
class ContactService {
  static const SystemContactPicker _picker = SystemContactPicker();

  /// Returns null when the user cancels. Throws if the picker cannot be opened,
  /// so the caller can fall back to manual entry.
  static Future<PickedPerson?> pick() async {
    final c = await _picker.pickContact(fields: const {ContactField.name, ContactField.phone});
    if (c == null) return null;
    final phones = <String>[];
    for (final p in c.phones) {
      final n = normalizePhone(p.value);
      if (n != null && !phones.contains(n)) phones.add(n);
    }
    return PickedPerson(c.displayName.trim(), phones);
  }
}
