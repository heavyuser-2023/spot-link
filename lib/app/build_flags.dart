/// Compile-time build flags.
///
/// `kStoreBuild` is true for Google Play builds, which must not include the
/// offline APK self-distribution feature (REQUEST_INSTALL_PACKAGES is a
/// restricted permission on Play and the feature violates Device & Network
/// Abuse policy for store-distributed apps).
///
/// Play build:
///   flutter build appbundle --flavor store --dart-define=STORE_BUILD=true
/// Sideload (GitHub releases) build:
///   flutter build apk --flavor sideload
const bool kStoreBuild = bool.fromEnvironment('STORE_BUILD');
