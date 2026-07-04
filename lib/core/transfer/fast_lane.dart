import 'dart:async';
import 'dart:typed_data';

/// The kind of direct Wi-Fi transport a device can offer for a bulk transfer.
/// Values are wire-stable (sent in a negotiation frame) — append only.
enum FastLaneKind {
  wifiAware(1), // Android Wi-Fi Aware (NAN)
  wifiDirect(2), // Android Wi-Fi Direct (WifiP2p)
  multipeer(3); // iOS/macOS MultipeerConnectivity (AWDL)

  final int code;
  const FastLaneKind(this.code);

  static FastLaneKind? fromCode(int c) {
    for (final k in FastLaneKind.values) {
      if (k.code == c) return k;
    }
    return null;
  }
}

/// Opaque connection info the receiver hands back over BLE so the sender can
/// dial a direct Wi-Fi channel. [blob] is platform-specific (e.g. Wi-Fi Aware
/// publish info, SoftAP SSID+psk, or a MultipeerConnectivity token).
class FastLaneOffer {
  final FastLaneKind kind;
  final Uint8List blob;
  const FastLaneOffer(this.kind, this.blob);
}

/// A live, bidirectional byte channel over the fast lane. Reliability and
/// ordering are the transport's job (TCP / OS), so the mesh sends the whole
/// ciphertext as a single length-prefixed blob — no chunk/ACK/window logic.
abstract class FastLaneSession {
  /// Bytes arriving from the peer.
  Stream<Uint8List> get incoming;

  /// Send bytes to the peer.
  void add(Uint8List data);

  /// Politely finish sending (half-close); safe to call once.
  Future<void> finishSending();

  /// Tear the channel down (releases the Wi-Fi radio).
  Future<void> close();
}

/// Optional bulk-transfer accelerator injected into [MeshNode]. When absent
/// (the default), the node uses BLE chunking for everything — so this is a
/// pure, opt-in upgrade with BLE always available as the fallback.
///
/// The control plane (discovery, negotiation, delivery ACK) stays on BLE;
/// this interface only moves the file *bytes*.
abstract class FastLaneInterface {
  /// What this device can offer right now (empty ⇒ no fast lane available,
  /// so every transfer stays on BLE).
  Set<FastLaneKind> get capabilities;

  /// Receiver side: begin listening for one inbound transfer and return the
  /// connection info to send back over BLE. Returns null if it can't (→ BLE).
  /// The returned session completes when the sender connects.
  Future<FastLaneInbound?> prepareInbound(
    String transferIdHex,
    FastLaneKind kind,
  );

  /// Sender side: dial the receiver using the [offer] it returned over BLE.
  /// Returns a connected session, or null on failure (→ BLE fallback).
  Future<FastLaneSession?> connect(String transferIdHex, FastLaneOffer offer);
}

/// The receiver's half: the offer to advertise over BLE plus a future that
/// resolves to the session once the sender connects (or null on timeout).
class FastLaneInbound {
  final FastLaneOffer offer;
  final Future<FastLaneSession?> session;
  const FastLaneInbound(this.offer, this.session);
}
