import Flutter
import Foundation
import MultipeerConnectivity

/// Wi-Fi fast lane for iOS via MultipeerConnectivity (AWDL — AP-less P2P over
/// Wi-Fi/BLE, Apple devices only). Implements the `spotlink/fastlane` channel
/// contract used by Dart's PlatformFastLane: the mesh negotiates over BLE and
/// hands transferId + connection info here; this moves the file bytes.
///
/// NOTE: Implemented per Apple's MultipeerConnectivity API. Not runtime-verified
/// in this build — needs two iOS devices to validate on hardware.
class FastLanePlugin: NSObject, FlutterStreamHandler {
  private let serviceType = "spotlink-ft" // 1–15 chars, [a-z0-9-]
  private let myPeerId = MCPeerID(displayName: UUID().uuidString.prefix(8).description)

  private var eventSink: FlutterEventSink?

  // Per-transfer MC objects.
  private var sessions = [String: MCSession]()
  private var advertisers = [String: MCNearbyServiceAdvertiser]()
  private var browsers = [String: MCNearbyServiceBrowser]()

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FastLanePlugin()
    let method = FlutterMethodChannel(
      name: "spotlink/fastlane", binaryMessenger: registrar.messenger())
    method.setMethodCallHandler(instance.handle)
    let events = FlutterEventChannel(
      name: "spotlink/fastlane/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  // MARK: FlutterStreamHandler
  func onListen(withArguments _: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = eventSink
    return nil
  }
  func onCancel(withArguments _: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func emit(_ tid: String, _ event: String, data: Data? = nil) {
    guard let sink = eventSink else { return }
    var map: [String: Any] = ["transferId": tid, "event": event]
    if let d = data { map["data"] = FlutterStandardTypedData(bytes: d) }
    DispatchQueue.main.async { sink(map) }
  }

  // MARK: MethodChannel
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let tid = args?["transferId"] as? String
    switch call.method {
    case "capabilities":
      result(["multipeer"])
    case "prepareInbound":
      guard let tid = tid else { result(nil); return }
      prepareInbound(tid, result: result)
    case "connect":
      guard let tid = tid, let blob = (args?["blob"] as? FlutterStandardTypedData)?.data
      else { result(false); return }
      connect(tid, blob: blob, result: result)
    case "send":
      if let tid = tid, let d = (args?["data"] as? FlutterStandardTypedData)?.data {
        send(tid, d)
      }
      result(nil)
    case "finishSending":
      result(nil) // receiver completes on the Dart length-prefix; no EOF needed
    case "close":
      if let tid = tid { teardown(tid) }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func makeSession() -> MCSession {
    let s = MCSession(peer: myPeerId, securityIdentity: nil, encryptionPreference: .required)
    s.delegate = self
    return s
  }

  // Receiver: advertise this transferId and wait for the sender to connect.
  private func prepareInbound(_ tid: String, result: @escaping FlutterResult) {
    let session = makeSession()
    sessions[tid] = session
    let adv = MCNearbyServiceAdvertiser(
      peer: myPeerId, discoveryInfo: ["tid": tid], serviceType: serviceType)
    adv.delegate = self
    advertisers[tid] = adv
    adv.startAdvertisingPeer()
    // The sender matches us by the tid in discoveryInfo; blob is unused.
    result(FlutterStandardTypedData(bytes: Data([1])))
  }

  // Sender: browse for the advertiser carrying this transferId, then invite.
  private func connect(_ tid: String, blob _: Data, result: @escaping FlutterResult) {
    let session = makeSession()
    sessions[tid] = session
    let browser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: serviceType)
    browser.delegate = self
    browsers[tid] = browser
    browser.startBrowsingForPeers()
    result(true) // "started"; actual connection arrives via the event stream
  }

  private func send(_ tid: String, _ data: Data) {
    guard let session = sessions[tid], !session.connectedPeers.isEmpty else { return }
    try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
  }

  private func teardown(_ tid: String) {
    advertisers[tid]?.stopAdvertisingPeer()
    advertisers[tid] = nil
    browsers[tid]?.stopBrowsingForPeers()
    browsers[tid] = nil
    sessions[tid]?.disconnect()
    sessions[tid] = nil
  }

  // Map an MCSession back to its transferId.
  private func tidFor(_ session: MCSession) -> String? {
    sessions.first(where: { $0.value === session })?.key
  }
}

// MARK: - MCSessionDelegate
extension FastLanePlugin: MCSessionDelegate {
  func session(_ session: MCSession, peer _: MCPeerID, didChange state: MCSessionState) {
    guard let tid = tidFor(session) else { return }
    switch state {
    case .connected:
      emit(tid, "connected")
    case .notConnected:
      emit(tid, "eof")
      // Drop this transfer's MC objects so stale advertisers/sessions don't
      // accumulate across retries and cross-talk between transfers.
      teardown(tid)
    default:
      break
    }
  }
  func session(_ session: MCSession, didReceive data: Data, fromPeer _: MCPeerID) {
    guard let tid = tidFor(session) else { return }
    emit(tid, "data", data: data)
  }
  func session(_: MCSession, didReceive _: InputStream, withName _: String, fromPeer _: MCPeerID) {}
  func session(_: MCSession, didStartReceivingResourceWithName _: String, fromPeer _: MCPeerID, with _: Progress) {}
  func session(_: MCSession, didFinishReceivingResourceWithName _: String, fromPeer _: MCPeerID, at _: URL?, withError _: Error?) {}
}

// MARK: - Advertiser (receiver side)
extension FastLanePlugin: MCNearbyServiceAdvertiserDelegate {
  func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                  didReceiveInvitationFromPeer _: MCPeerID,
                  withContext _: Data?,
                  invitationHandler: @escaping (Bool, MCSession?) -> Void) {
    // Accept into the session prepared for THIS advertiser's transfer.
    if let tid = advertisers.first(where: { $0.value === advertiser })?.key,
       let session = sessions[tid] {
      invitationHandler(true, session)
    } else {
      invitationHandler(false, nil)
    }
  }
}

// MARK: - Browser (sender side)
extension FastLanePlugin: MCNearbyServiceBrowserDelegate {
  func browser(_ browser: MCNearbyServiceBrowser,
               foundPeer peerID: MCPeerID,
               withDiscoveryInfo info: [String: String]?) {
    guard let tid = info?["tid"], let session = sessions[tid] else { return }
    browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
  }
  func browser(_: MCNearbyServiceBrowser, lostPeer _: MCPeerID) {}
}
