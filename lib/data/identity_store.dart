import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/crypto/identity.dart';

/// 노드의 [Identity]를 로드하거나 생성하며, 개인 시드를 플랫폼 보안
/// 엔클레이브(Keychain / Keystore)에 영구 저장한다.
class IdentityStore {
  static const _keyIdentity = 'spotlink_identity_v1';
  static const _keyName = 'spotlink_display_name';

  /// v2: 이 플래그의 v1은 legacy 항목을 볼 수 없어(accessibility 필터링된
  /// 읽기) 아무것도 마이그레이션하지 못한 버그 있는 마이그레이션이 설정한
  /// 것이다 — 완전히 무시한다.
  static const _keyMigrated = 'spotlink_kc_migrated_v2';

  /// iOS: `first_unlock` accessibility가 아니면, 잠긴 폰에서의 백그라운드
  /// 재실행(CoreBluetooth 상태 복원 / 비콘 웨이크)이 신원을 읽을 수 없다 —
  /// 기본 when-unlocked 클래스는 errSecInteraction NotAllowed (-25308)를
  /// 던지고 메시 전체가 헤드리스로 부팅되지 못한다.
  static const _iosOptions =
      IOSOptions(accessibility: KeychainAccessibility.first_unlock);

  /// macOS: data-protection 키체인이 아니라 LEGACY(파일 기반) 키체인을
  /// 사용한다. data-protection 키체인은 keychain-access-group entitlement
  /// (즉 팀 서명)를 요구한다; ad-hoc / 미서명 로컬 빌드에는 그것이 없어
  /// 모든 SecItem 호출이 errSecMissingEntitlement (-34018)를 던지고 신원을
  /// 저장할 수 없다. macOS 전용 — iOS/Android 옵션은 건드리지 않는다.
  static const _macOptions =
      MacOsOptions(usesDataProtectionKeychain: false);

  /// 새 클래스 저장소. 참고: accessibility 옵션이 설정되면, iOS의 읽기와
  /// 쓰기는 해당 클래스의 항목만 매칭한다 — 기본 when-unlocked 클래스로
  /// 쓰인 legacy 항목은 이 저장소에 보이지 않으며(덮어쓸 수도 없다:
  /// 쓰기가 errSecDuplicateItem을 만난다), 그래서 아래 [_legacy]가 있다.
  final FlutterSecureStorage _storage;

  /// 옵션 없는 저장소로, 쿼리가 모든 accessibility 클래스와 매칭된다 —
  /// 마이그레이션 이전 항목을 읽거나 삭제하는 유일한 방법이다.
  final FlutterSecureStorage _legacy;

  IdentityStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
                iOptions: _iosOptions, mOptions: _macOptions),
        _legacy = storage ?? const FlutterSecureStorage(mOptions: _macOptions);

  /// legacy(when-unlocked) 항목을 first_unlock 클래스로 옮긴다. 백업 슬롯이
  /// delete+rewrite를 감싸므로 그 사이에 크래시가 나도 절대 신원을 잃지
  /// 않는다 (신원을 잃으면 peer ID가 바뀌고 모든 친구 관계가 깨진다).
  /// 반복 호출해도 안전하다; 복사는 최대 한 번만 수행한다.
  Future<void> _migrateAccessibility() async {
    try {
      if (await _storage.read(key: _keyMigrated) == '1') return;
      for (final key in [_keyIdentity, _keyName]) {
        if (await _storage.read(key: key) != null) continue; // 이미 새 클래스
        final value = await _legacy.read(key: key);
        if (value == null) continue;
        await _storage.write(key: '$key.bak', value: value);
        await _legacy.delete(key: key);
        await _storage.write(key: key, value: value);
        await _storage.delete(key: '$key.bak');
      }
      await _storage.write(key: _keyMigrated, value: '1');
    } catch (_) {
      // 잠김 또는 일시적 키체인 실패 — 이후 호출에서 재시도된다.
    }
  }

  Future<Identity> loadOrCreate() async {
    await _migrateAccessibility();
    var existing = await _storage.read(key: _keyIdentity);
    // 크래시 복구: delete와 write 사이에 중단된 마이그레이션이 값을 백업
    // 슬롯에만 남겨 둔 경우.
    existing ??= await _storage.read(key: '$_keyIdentity.bak');
    // 아직 마이그레이션되지 않음 (예: 마이그레이션 중 키체인 잠김): 새로
    // 생성해 모든 친구를 고아로 만드는 대신 legacy 항목으로 폴백한다.
    existing ??= await _legacy.read(key: _keyIdentity);
    if (existing != null) {
      try {
        return await Identity.importPrivate(existing);
      } catch (_) {
        // 손상된 항목 — 새로 생성한다.
      }
    }
    final id = await Identity.generate();
    await _storage.write(key: _keyIdentity, value: await id.exportPrivate());
    return id;
  }

  static const defaultName = 'SpotLink User';

  Future<String> displayName() async => await storedName() ?? defaultName;

  /// 저장된 이름, 또는 사용자가 한 번도 설정하지 않았으면 null (첫 실행).
  Future<String?> storedName() async {
    await _migrateAccessibility();
    return await _storage.read(key: _keyName) ??
        await _storage.read(key: '$_keyName.bak') ??
        await _legacy.read(key: _keyName);
  }

  Future<void> setDisplayName(String name) async {
    await _migrateAccessibility();
    // legacy 클래스 항목을 먼저 지운다; 그렇지 않으면 새 클래스 쓰기가
    // 그것과 충돌한다 (errSecDuplicateItem).
    try {
      await _legacy.delete(key: _keyName);
    } catch (_) {}
    await _storage.write(key: _keyName, value: name);
  }
}
