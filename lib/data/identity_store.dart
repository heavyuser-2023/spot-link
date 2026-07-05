import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/crypto/identity.dart';

/// Loads or creates the node's [Identity], persisting the private seeds in the
/// platform secure enclave (Keychain / Keystore).
class IdentityStore {
  static const _keyIdentity = 'spotlink_identity_v1';
  static const _keyName = 'spotlink_display_name';

  /// v2: v1 of this flag was set by a buggy migration that couldn't see the
  /// legacy items (accessibility-filtered reads) and therefore migrated
  /// nothing — ignore it entirely.
  static const _keyMigrated = 'spotlink_kc_migrated_v2';

  /// iOS: `first_unlock` accessibility, or a background relaunch on a locked
  /// phone (CoreBluetooth state restoration / beacon wake) cannot read the
  /// identity — the default when-unlocked class throws errSecInteraction
  /// NotAllowed (-25308) and the whole mesh fails to boot headless.
  static const _iosOptions =
      IOSOptions(accessibility: KeychainAccessibility.first_unlock);

  /// New-class storage. NOTE: with an accessibility option set, iOS reads
  /// and writes only match items of that class — legacy items written with
  /// the default when-unlocked class are invisible to it (and un-overwritable:
  /// writes hit errSecDuplicateItem). Hence [_legacy] below.
  final FlutterSecureStorage _storage;

  /// Option-less storage whose queries match any accessibility class — the
  /// only way to read/delete pre-migration items.
  final FlutterSecureStorage _legacy;

  IdentityStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage(iOptions: _iosOptions),
        _legacy = storage ?? const FlutterSecureStorage();

  /// Move legacy (when-unlocked) items to the first_unlock class. A backup
  /// slot brackets the delete+rewrite so a crash in between can never lose
  /// the identity (losing it changes our peer ID and breaks every
  /// friendship). Safe to call repeatedly; runs the copy at most once.
  Future<void> _migrateAccessibility() async {
    try {
      if (await _storage.read(key: _keyMigrated) == '1') return;
      for (final key in [_keyIdentity, _keyName]) {
        if (await _storage.read(key: key) != null) continue; // already new
        final value = await _legacy.read(key: key);
        if (value == null) continue;
        await _storage.write(key: '$key.bak', value: value);
        await _legacy.delete(key: key);
        await _storage.write(key: key, value: value);
        await _storage.delete(key: '$key.bak');
      }
      await _storage.write(key: _keyMigrated, value: '1');
    } catch (_) {
      // Locked or transient keychain failure — retried on a later call.
    }
  }

  Future<Identity> loadOrCreate() async {
    await _migrateAccessibility();
    var existing = await _storage.read(key: _keyIdentity);
    // Crash-recovery: a migration interrupted between delete and write left
    // the value only in the backup slot.
    existing ??= await _storage.read(key: '$_keyIdentity.bak');
    // Not migrated yet (e.g. keychain locked during migration): fall back to
    // the legacy item rather than regenerating and orphaning every friend.
    existing ??= await _legacy.read(key: _keyIdentity);
    if (existing != null) {
      try {
        return await Identity.importPrivate(existing);
      } catch (_) {
        // Corrupt entry — regenerate.
      }
    }
    final id = await Identity.generate();
    await _storage.write(key: _keyIdentity, value: await id.exportPrivate());
    return id;
  }

  static const defaultName = 'SpotLink User';

  Future<String> displayName() async => await storedName() ?? defaultName;

  /// The stored name, or null if the user has never set one (first run).
  Future<String?> storedName() async {
    await _migrateAccessibility();
    return await _storage.read(key: _keyName) ??
        await _storage.read(key: '$_keyName.bak') ??
        await _legacy.read(key: _keyName);
  }

  Future<void> setDisplayName(String name) async {
    await _migrateAccessibility();
    // Clear any legacy-class item first or the new-class write collides
    // with it (errSecDuplicateItem).
    try {
      await _legacy.delete(key: _keyName);
    } catch (_) {}
    await _storage.write(key: _keyName, value: name);
  }
}
