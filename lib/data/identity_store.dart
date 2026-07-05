import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/crypto/identity.dart';

/// Loads or creates the node's [Identity], persisting the private seeds in the
/// platform secure enclave (Keychain / Keystore).
class IdentityStore {
  static const _keyIdentity = 'spotlink_identity_v1';
  static const _keyName = 'spotlink_display_name';
  static const _keyMigrated = 'spotlink_kc_first_unlock_v1';

  /// iOS: `first_unlock` accessibility, or a background relaunch on a locked
  /// phone (CoreBluetooth state restoration / beacon wake) cannot read the
  /// identity — the default when-unlocked class throws errSecInteraction
  /// NotAllowed (-25308) and the whole mesh fails to boot headless.
  static const _iosOptions =
      IOSOptions(accessibility: KeychainAccessibility.first_unlock);

  final FlutterSecureStorage _storage;

  IdentityStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage(iOptions: _iosOptions);

  /// Items written before the accessibility change keep their old
  /// when-unlocked class — rewrite them once (delete+write re-creates the
  /// keychain item with the new class). Runs only while unlocked, which is
  /// guaranteed on the interactive path that calls this.
  Future<void> _migrateAccessibility() async {
    try {
      if (await _storage.read(key: _keyMigrated) == '1') return;
      for (final key in [_keyIdentity, _keyName]) {
        final value = await _storage.read(key: key);
        if (value != null) {
          // Keep a backup across the delete+write so a crash in between can
          // never lose the identity (losing it changes our peer ID and
          // breaks every friendship).
          await _storage.write(key: '$key.bak', value: value);
          await _storage.delete(key: key);
          await _storage.write(key: key, value: value);
          await _storage.delete(key: '$key.bak');
        }
      }
      await _storage.write(key: _keyMigrated, value: '1');
    } catch (_) {
      // Locked or transient keychain failure — retried on a later launch.
    }
  }

  Future<Identity> loadOrCreate() async {
    await _migrateAccessibility();
    var existing = await _storage.read(key: _keyIdentity);
    // Crash-recovery: a migration interrupted between delete and write left
    // the value only in the backup slot.
    existing ??= await _storage.read(key: '$_keyIdentity.bak');
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

  Future<String> displayName() async {
    return await _storage.read(key: _keyName) ?? defaultName;
  }

  /// The stored name, or null if the user has never set one (first run).
  Future<String?> storedName() async => _storage.read(key: _keyName);

  Future<void> setDisplayName(String name) async {
    await _storage.write(key: _keyName, value: name);
  }
}
