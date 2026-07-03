import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/crypto/identity.dart';

/// Loads or creates the node's [Identity], persisting the private seeds in the
/// platform secure enclave (Keychain / Keystore).
class IdentityStore {
  static const _keyIdentity = 'spotlink_identity_v1';
  static const _keyName = 'spotlink_display_name';

  final FlutterSecureStorage _storage;

  IdentityStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  Future<Identity> loadOrCreate() async {
    final existing = await _storage.read(key: _keyIdentity);
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
