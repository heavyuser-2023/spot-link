import Flutter
import Foundation
import MultipeerConnectivity
import UIKit

/// MultipeerConnectivity (AWDL) iOS fast lane for file bytes.
///
/// Dart `PlatformFastLane` contract on `spotlink/fastlane` + events channel.
///
/// Design notes (learned from real-device failures on iPhone↔iPhone):
/// - Multipeer does **not** tolerate many concurrent Advertiser/Browser pairs.
///   Six simultaneous transfers each spawning their own MCSession caused every
///   connect to time out (`FT fast connect null` / `no session`). This plugin
///   therefore allows **one active transfer at a time**; further requests get
///   `nil`/`false` so Dart falls back (or retries after the lock frees).
/// - Advertise/browse stop as soon as the session is connected to free the
///   radio for the next transfer.
/// - Errors from MC are forwarded as `event: error` so Dart does not wait the
///   full 25s timeout silently.
class FastLanePlugin: NSObject, FlutterStreamHandler {
  private let serviceType = "spotlink-ft" // 1…15 chars, [a-z0-9-]
  /// One peer identity for the process lifetime (MC requirement).
  /// 가명을 쓴다 — UIDevice.current.name("○○의 iPhone")은 AWDL 광고로 주변
  /// 모두에게 평문 노출된다. 상대 식별은 discoveryInfo/컨텍스트의 tid가 하므로
  /// 표시 이름은 아무 의미도 담을 필요가 없다.
  private let myPeerId = MCPeerID(
    displayName: "SL-" + String(format: "%08x", UInt32.random(in: .min ... .max)))

  private var eventSink: FlutterEventSink?

  /// Only one transfer may own MC objects at a time.
  private var activeTid: String?
  private var session: MCSession?
  private var advertiser: MCNearbyServiceAdvertiser?
  private var browser: MCNearbyServiceBrowser?
  /// Browser side: tid we are trying to reach (must match discoveryInfo).
  private var browsingForTid: String?
  private var connectedEmitted = false
  /// 잔상 discoveryInfo로 인한 브라우저 재시작의 스로틀.
  private var lastBrowseRestart = Date.distantPast

  /// 발견 캐시를 비우기 위한 브라우저 교체(디바운스 1.5초). foundPeer가
  /// 낡은 tid만 물고 있을 때 새 광고를 다시 받는 유일한 방법이다.
  ///
  /// 반드시 "재시작"이 아니라 "교체"여야 한다: 같은 인스턴스에 stop→start를
  /// 걸면 CFNetService 브라우저의 런루프 소스가 이중 무효화되어 메인 스레드
  /// EXC_BREAKPOINT로 죽는다(2026-07-17 실기기 크래시, _BrowserCancel →
  /// CFRunLoopSourceInvalidate assertion). MC 브라우저는 일회용으로 취급한다 —
  /// 새 인스턴스를 세우고, 옛것은 델리게이트만 떼어 조용히 버린다(명시적
  /// stop 없이 해제되게 두면 취소 경로가 딱 한 번만 탄다).
  private func restartBrowsingSoon() {
    guard Date().timeIntervalSince(lastBrowseRestart) > 1.5 else { return }
    lastBrowseRestart = Date()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self = self, self.browsingForTid != nil,
            let old = self.browser else { return }
      old.delegate = nil
      let fresh = MCNearbyServiceBrowser(
        peer: self.myPeerId, serviceType: self.serviceType)
      fresh.delegate = self
      self.browser = fresh
      fresh.startBrowsingForPeers()
      self.log("browser replaced (stale discoveryInfo)")
    }
  }

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

  private func log(_ msg: String) {
    NSLog("SpotLink FastLane: %@", msg)
    // Also surface to Dart when a transfer is active (ble.log via PlatformFastLane).
    if let tid = activeTid {
      guard let sink = eventSink else { return }
      let map: [String: Any] = [
        "transferId": tid, "event": "log", "message": msg,
      ]
      DispatchQueue.main.async { sink(map) }
    }
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
      result(nil) // receiver uses Dart length-prefix; no native EOF needed
    case "close":
      if let tid = tid { teardown(tid, reason: "close") }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func makeSession() -> MCSession {
    // `.optional` is more reliable than `.required` for first-time nearby pairs
    // (required can stall with no UI when encryption negotiation fails).
    let s = MCSession(
      peer: myPeerId, securityIdentity: nil, encryptionPreference: .optional)
    s.delegate = self
    return s
  }

  /// Receiver: advertise this transferId; sender will browse + invite.
  private func prepareInbound(_ tid: String, result: @escaping FlutterResult) {
    if let active = activeTid, active != tid {
      log("prepareInbound busy (active=\(active)) — reject \(tid)")
      result(nil)
      return
    }
    teardown(tid, reason: "re-prepare")
    activeTid = tid
    connectedEmitted = false
    let session = makeSession()
    self.session = session
    // discoveryInfo value length is fine for 32-char hex tid.
    let adv = MCNearbyServiceAdvertiser(
      peer: myPeerId, discoveryInfo: ["tid": tid], serviceType: serviceType)
    adv.delegate = self
    advertiser = adv
    adv.startAdvertisingPeer()
    log("advertising tid=\(tid)")
    // Blob unused by Multipeer path; non-empty so Dart treats offer as valid.
    result(FlutterStandardTypedData(bytes: Data([1])))
  }

  /// Sender: browse for an advertiser whose discoveryInfo.tid matches.
  private func connect(_ tid: String, blob _: Data, result: @escaping FlutterResult) {
    if let active = activeTid, active != tid {
      log("connect busy (active=\(active)) — reject \(tid)")
      result(false)
      return
    }
    teardown(tid, reason: "re-connect")
    activeTid = tid
    browsingForTid = tid
    connectedEmitted = false
    let session = makeSession()
    self.session = session
    let browser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: serviceType)
    browser.delegate = self
    self.browser = browser
    browser.startBrowsingForPeers()
    log("browsing for tid=\(tid)")
    result(true) // actual connect arrives on the event stream
  }

  private func send(_ tid: String, _ data: Data) {
    guard tid == activeTid, let session = session, !session.connectedPeers.isEmpty else {
      log("send dropped (no peers) tid=\(tid) bytes=\(data.count)")
      return
    }
    do {
      try session.send(data, toPeers: session.connectedPeers, with: .reliable)
    } catch {
      log("send error: \(error.localizedDescription)")
      emit(tid, "error")
    }
  }

  private func teardown(_ tid: String, reason: String) {
    if activeTid != nil && activeTid != tid { return }
    if activeTid != nil {
      log("teardown tid=\(tid) reason=\(reason)")
    }
    advertiser?.stopAdvertisingPeer()
    advertiser?.delegate = nil
    advertiser = nil
    browser?.stopBrowsingForPeers()
    browser?.delegate = nil
    browser = nil
    browsingForTid = nil
    session?.delegate = nil
    session?.disconnect()
    session = nil
    if activeTid == tid { activeTid = nil }
    connectedEmitted = false
  }

  private func markConnected(_ tid: String) {
    guard tid == activeTid, !connectedEmitted else { return }
    connectedEmitted = true
    // Free discovery once the pipe is up so the next transfer can start cleanly.
    advertiser?.stopAdvertisingPeer()
    browser?.stopBrowsingForPeers()
    log("connected tid=\(tid)")
    emit(tid, "connected")
  }
}

// MARK: - MCSessionDelegate
extension FastLanePlugin: MCSessionDelegate {
  func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
    guard session === self.session, let tid = activeTid else { return }
    switch state {
    case .connected:
      markConnected(tid)
    case .notConnected:
      log("peer \(peerID.displayName) notConnected tid=\(tid)")
      if connectedEmitted {
        emit(tid, "eof")
      } else {
        // Failed before ever connecting — unblock Dart timeout early.
        emit(tid, "error")
      }
      teardown(tid, reason: "notConnected")
    case .connecting:
      log("connecting to \(peerID.displayName) tid=\(tid)")
    @unknown default:
      break
    }
  }

  func session(_ session: MCSession, didReceive data: Data, fromPeer _: MCPeerID) {
    guard session === self.session, let tid = activeTid else { return }
    emit(tid, "data", data: data)
  }

  func session(_: MCSession, didReceive _: InputStream, withName _: String, fromPeer _: MCPeerID) {}
  func session(_: MCSession, didStartReceivingResourceWithName _: String, fromPeer _: MCPeerID, with _: Progress) {}
  func session(_: MCSession, didFinishReceivingResourceWithName _: String, fromPeer _: MCPeerID, at _: URL?, withError _: Error?) {}
  func session(_: MCSession, didReceiveCertificate _: [Any]?, fromPeer _: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
    certificateHandler(true)
  }
}

// MARK: - Advertiser (receiver)
extension FastLanePlugin: MCNearbyServiceAdvertiserDelegate {
  func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                  didReceiveInvitationFromPeer peerID: MCPeerID,
                  withContext context: Data?,
                  invitationHandler: @escaping (Bool, MCSession?) -> Void) {
    guard advertiser === self.advertiser, let session = session, let tid = activeTid else {
      invitationHandler(false, nil)
      return
    }
    // Prefer context tid when present (sender puts it there); else accept for active.
    if let context = context, let ctxTid = String(data: context, encoding: .utf8),
       ctxTid != tid {
      log("reject invite wrong ctx tid=\(ctxTid) active=\(tid)")
      invitationHandler(false, nil)
      return
    }
    log("accept invite from \(peerID.displayName) tid=\(tid)")
    invitationHandler(true, session)
  }

  func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                  didNotStartAdvertisingPeer error: Error) {
    log("advertiser failed: \(error.localizedDescription)")
    if let tid = activeTid {
      emit(tid, "error")
      teardown(tid, reason: "adv-fail")
    }
  }
}

// MARK: - Browser (sender)
extension FastLanePlugin: MCNearbyServiceBrowserDelegate {
  func browser(_ browser: MCNearbyServiceBrowser,
               foundPeer peerID: MCPeerID,
               withDiscoveryInfo info: [String: String]?) {
    guard browser === self.browser,
          let want = browsingForTid,
          let session = session else { return }
    let found = info?["tid"]
    guard found == want else {
      log("ignore peer \(peerID.displayName) tid=\(found ?? "nil") want=\(want)")
      // MC 브라우저는 한 번 찾은 피어의 discoveryInfo가 바뀌어도 foundPeer를
      // 다시 쏘지 않을 수 있다: 연속 전송에서 직전 tid의 잔상 광고를 보고
      // 여기로 빠지면 25초 내내 침묵하다 BLE로 폴백한다(관찰: 파일 4개 중
      // 3번째부터 "fast connect null"). stop→start로 발견 캐시를 비워 새
      // 광고가 신선한 foundPeer로 다시 들어오게 한다.
      restartBrowsingSoon()
      return
    }
    log("invite \(peerID.displayName) for tid=\(want)")
    let ctx = want.data(using: .utf8)
    browser.invitePeer(peerID, to: session, withContext: ctx, timeout: 20)
  }

  func browser(_: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    log("lost peer \(peerID.displayName)")
  }

  func browser(_ browser: MCNearbyServiceBrowser,
               didNotStartBrowsingForPeers error: Error) {
    log("browser failed: \(error.localizedDescription)")
    if let tid = activeTid {
      emit(tid, "error")
      teardown(tid, reason: "browse-fail")
    }
  }
}
