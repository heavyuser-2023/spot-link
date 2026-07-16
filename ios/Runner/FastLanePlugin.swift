import Flutter
import Foundation
import MultipeerConnectivity

/// MultipeerConnectivity를 이용한 iOS용 Wi-Fi 패스트 레인 (AWDL — Wi-Fi/BLE
/// 상에서 AP 없이 동작하는 P2P, Apple 기기 전용). Dart의 PlatformFastLane이
/// 사용하는 `spotlink/fastlane` 채널 계약을 구현한다: 메시가 BLE로 협상하고
/// transferId + 연결 정보를 여기로 넘겨주면, 이 코드가 파일 바이트를 옮긴다.
///
/// NOTE: Apple의 MultipeerConnectivity API대로 구현했다. 이 빌드에서는 런타임
/// 검증이 되지 않았다 — 하드웨어 검증에는 iOS 기기 두 대가 필요하다.
class FastLanePlugin: NSObject, FlutterStreamHandler {
  private let serviceType = "spotlink-ft" // 1~15자, [a-z0-9-]
  private let myPeerId = MCPeerID(displayName: UUID().uuidString.prefix(8).description)

  private var eventSink: FlutterEventSink?

  // 전송 단위별 MC 객체들.
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
      result(nil) // 수신 측은 Dart의 길이 접두사로 완료를 판단한다; EOF 불필요
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

  // 수신 측: 이 transferId를 광고하고 송신 측이 연결해 오기를 기다린다.
  private func prepareInbound(_ tid: String, result: @escaping FlutterResult) {
    let session = makeSession()
    sessions[tid] = session
    let adv = MCNearbyServiceAdvertiser(
      peer: myPeerId, discoveryInfo: ["tid": tid], serviceType: serviceType)
    adv.delegate = self
    advertisers[tid] = adv
    adv.startAdvertisingPeer()
    // 송신 측은 discoveryInfo의 tid로 우리를 매칭한다; blob은 사용하지 않는다.
    result(FlutterStandardTypedData(bytes: Data([1])))
  }

  // 송신 측: 이 transferId를 지닌 advertiser를 탐색한 뒤 초대한다.
  private func connect(_ tid: String, blob _: Data, result: @escaping FlutterResult) {
    let session = makeSession()
    sessions[tid] = session
    let browser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: serviceType)
    browser.delegate = self
    browsers[tid] = browser
    browser.startBrowsingForPeers()
    result(true) // "시작됨"; 실제 연결은 이벤트 스트림을 통해 도착한다
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

  // MCSession을 그 transferId로 역매핑한다.
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
      // 이 전송의 MC 객체들을 버려서, 오래된 advertiser/session이 재시도를
      // 거치며 쌓여 전송끼리 서로 간섭하지 않도록 한다.
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

// MARK: - Advertiser (수신 측)
extension FastLanePlugin: MCNearbyServiceAdvertiserDelegate {
  func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                  didReceiveInvitationFromPeer _: MCPeerID,
                  withContext _: Data?,
                  invitationHandler: @escaping (Bool, MCSession?) -> Void) {
    // THIS advertiser의 전송을 위해 준비된 세션으로 수락한다.
    if let tid = advertisers.first(where: { $0.value === advertiser })?.key,
       let session = sessions[tid] {
      invitationHandler(true, session)
    } else {
      invitationHandler(false, nil)
    }
  }
}

// MARK: - Browser (송신 측)
extension FastLanePlugin: MCNearbyServiceBrowserDelegate {
  func browser(_ browser: MCNearbyServiceBrowser,
               foundPeer peerID: MCPeerID,
               withDiscoveryInfo info: [String: String]?) {
    guard let tid = info?["tid"], let session = sessions[tid] else { return }
    browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
  }
  func browser(_: MCNearbyServiceBrowser, lostPeer _: MCPeerID) {}
}
