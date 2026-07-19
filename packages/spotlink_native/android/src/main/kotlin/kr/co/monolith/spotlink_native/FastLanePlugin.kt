package kr.co.monolith.spotlink_native

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * Wi-Fi Direct(Wi-Fi P2P)를 이용한 Android용 Wi-Fi 패스트 레인. 수신 측은
 * 자율 그룹을 생성하고(192.168.49.1의 임시 SoftAP / 그룹 오너 역할) 자신의
 * SSID+passphrase를 BLE로 광고한다; 송신 측은 [WifiNetworkSpecifier]로 그
 * Wi-Fi에 접속하며, 양쪽은 평범한 TCP 소켓으로 파일 바이트를 옮긴다. 메시는
 * 여전히 BLE로 협상/암호화/ACK를 수행한다.
 *
 * Dart의 PlatformFastLane이 사용하는 `spotlink/fastlane` 채널 계약을 구현한다.
 * NOTE: Android API대로 작성했으나 이 빌드에서는 런타임 검증이 되지 않았다 —
 * 하드웨어 검증에는 Android 기기 두 대가 필요하다.
 */
class FastLanePlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private lateinit var context: Context
    private var events: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    private val p2p by lazy {
        context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    }
    private val p2pChannel by lazy { p2p?.initialize(context, Looper.getMainLooper(), null) }

    private val transfers = HashMap<String, Transfer>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        MethodChannel(binding.binaryMessenger, "spotlink/fastlane")
            .setMethodCallHandler(this)
        EventChannel(binding.binaryMessenger, "spotlink/fastlane/events")
            .setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}

    override fun onListen(args: Any?, sink: EventChannel.EventSink?) { events = sink }
    override fun onCancel(args: Any?) { events = null }

    private fun emit(tid: String, event: String, data: ByteArray? = null) {
        val map = HashMap<String, Any>()
        map["transferId"] = tid
        map["event"] = event
        if (data != null) map["data"] = data
        main.post { events?.success(map) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val tid = call.argument<String>("transferId")
        when (call.method) {
            "capabilities" -> {
                // 기내(공유 AP 없음) 시나리오용으로 재활성화(2026-07-20).
                // 수신(rx) = 영속 그룹의 오너(SoftAP 호스트), 송신(tx) =
                // WifiNetworkSpecifier로 상대 그룹에 접속(시스템 확인 1탭).
                // iOS 피어는 NEHotspotConfiguration으로 이 그룹에 레거시
                // 클라이언트로 접속한다(Android GO ← iOS 송신 방향 지원).
                // NOTE: 실기기 2대 런타임 검증은 아직 미완 — 실패 시 모든
                // 경로가 BLE로 폴백하므로 회귀 위험은 없다.
                val ok = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                    context.packageManager
                        .hasSystemFeature("android.hardware.wifi.direct")
                // tx의 wifiDirectHosted = 송신자-호스트 역방향(수신자가 AP를
                // 못 만드는 iPhone일 때): 우리가 그룹을 만들고 HOSTINFO로
                // 접속 정보를 넘기면 상대가 조인+다이얼한다.
                val rx = if (ok) listOf("wifiDirect") else emptyList<String>()
                val tx = if (ok) listOf("wifiDirect", "wifiDirectHosted")
                         else emptyList<String>()
                result.success(mapOf("tx" to tx, "rx" to rx))
            }
            "prepareInbound" -> {
                if (tid == null) { result.success(null); return }
                prepareInbound(tid, result)
            }
            "connect" -> {
                val blob = call.argument<ByteArray>("blob")
                if (tid == null || blob == null) { result.success(false); return }
                connect(tid, blob, result)
            }
            "send" -> {
                val data = call.argument<ByteArray>("data")
                if (tid != null && data != null) transfers[tid]?.write(data)
                result.success(null)
            }
            "finishSending" -> {
                if (tid != null) transfers[tid]?.finishSending()
                result.success(null)
            }
            "close" -> {
                if (tid != null) teardown(tid)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /// 기기당 한 번 생성해 재사용하는 그룹 자격(SSID/암호). 영속 모드 +
    /// 고정 자격이라 iOS의 NEHotspotConfiguration이 같은 SSID로 저장돼
    /// 두 번째 전송부터는 조인 동의 팝업이 없다.
    private fun stableGroupConfig(): WifiP2pConfig? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val prefs: SharedPreferences =
            context.getSharedPreferences("spotlink_fastlane", Context.MODE_PRIVATE)
        var name = prefs.getString("go_ssid", null)
        var pass = prefs.getString("go_pass", null)
        if (name == null || pass == null) {
            val alphabet = "abcdefghjkmnpqrstuvwxyz23456789"
            val rnd = java.security.SecureRandom()
            fun rand(n: Int) = (1..n).map { alphabet[rnd.nextInt(alphabet.length)] }
                .joinToString("")
            name = "DIRECT-SL" + rand(6) // 규격: ^DIRECT-[a-zA-Z0-9]{2}…
            pass = rand(12) // WPA2 8–63자
            prefs.edit().putString("go_ssid", name).putString("go_pass", pass).apply()
        }
        return WifiP2pConfig.Builder()
            .setNetworkName(name)
            .setPassphrase(pass)
            .enablePersistentMode(true)
            .build()
    }

    // 수신 측: 영속 그룹(SoftAP)을 만들고, 소켓에서 대기하며,
    // SSID+pass+ip:port를 광고한다. iOS/Android 송신자가 이 그룹에 접속해
    // 그룹 오너(192.168.49.1)의 리스너로 다이얼한다.
    @Suppress("MissingPermission")
    private fun prepareInbound(tid: String, result: MethodChannel.Result) {
        val mgr = p2p
        val ch = p2pChannel
        val config = stableGroupConfig()
        if (mgr == null || ch == null || config == null) {
            result.success(null); return
        }

        // 그룹 생성 직후 정보가 즉시 조회되지 않을 수 있다 — 짧게 재시도.
        fun advertise(attempt: Int) {
            mgr.requestGroupInfo(ch) { group ->
                if (group == null || !group.isGroupOwner) {
                    if (attempt < 5) {
                        main.postDelayed({ advertise(attempt + 1) }, 400)
                    } else {
                        result.success(null)
                    }
                    return@requestGroupInfo
                }
                // 그룹 오너 주소는 192.168.49.1로 고정되어 있다.
                val ownerIp = "192.168.49.1"
                val t = Transfer(tid)
                transfers[tid] = t
                // 임시 포트에 바인딩한 뒤 실제 포트를 광고한다 — 고정 포트
                // (예전 8988)는 동시 수신·TIME_WAIT 잔상과 충돌했고, 바인딩
                // 전에 blob부터 만들어 실패를 놓쳤다.
                val port = t.listen()
                if (port == null) { result.success(null); return@requestGroupInfo }
                val blob = "${group.networkName}\n${group.passphrase}\n$ownerIp\n$port"
                    .toByteArray(Charsets.UTF_8)
                result.success(blob)
            }
        }

        mgr.createGroup(ch, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { advertise(0) }
            override fun onFailure(reason: Int) {
                // BUSY = 직전 전송의 그룹이 아직 살아 있음 — 자격이 같으므로
                // 그대로 재사용한다. 그 외 실패도 조회로 확인 후 포기한다.
                advertise(0)
            }
        })
    }

    // 송신 측: 수신 측 그룹 SSID에 Wi-Fi 클라이언트로 접속한 뒤 다이얼한다.
    private fun connect(tid: String, blob: ByteArray, result: MethodChannel.Result) {
        val parts = String(blob, Charsets.UTF_8).split("\n")
        if (parts.size < 4 || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.success(false); return
        }
        val (ssid, pass, ip, portStr) = parts
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(pass)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()
        val t = Transfer(tid)
        transfers[tid] = t
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // 접속한 P2P 네트워크를 통해 그룹 오너로 다이얼한다.
                t.dial(network, ip, portStr.toInt())
            }
            override fun onUnavailable() {
                emit(tid, "error")
            }
        }
        t.networkCallback = callback
        t.connectivityManager = cm
        cm.requestNetwork(request, callback)
        result.success(true) // 연결 결과는 이벤트 스트림을 통해 도착한다
    }

    private fun teardown(tid: String) {
        transfers.remove(tid)?.close()
        // best-effort: 우리가 생성한 P2P 그룹이 있으면 제거한다.
        val mgr = p2p; val ch = p2pChannel
        if (mgr != null && ch != null) {
            mgr.removeGroup(ch, null)
        }
    }

    /** 한 전송의 소켓 + 리더/라이터 스레드. */
    inner class Transfer(private val tid: String) {
        private var server: ServerSocket? = null
        private var socket: Socket? = null
        private var out: OutputStream? = null
        @Volatile private var closed = false
        var networkCallback: ConnectivityManager.NetworkCallback? = null
        var connectivityManager: ConnectivityManager? = null

        /** 임시 포트에 바인딩하고 실제 포트를 반환한다(실패 시 null). */
        fun listen(): Int? {
            val ss = try { ServerSocket(0) } catch (e: Exception) { return null }
            server = ss
            thread {
                try {
                    val sock = ss.accept()
                    bind(sock)
                } catch (e: Exception) {
                    if (!closed) emit(tid, "error")
                }
            }
            return ss.localPort
        }

        fun dial(network: Network, ip: String, port: Int) = thread {
            try {
                val sock = network.socketFactory.createSocket()
                sock.connect(InetSocketAddress(ip, port), 8000)
                bind(sock)
            } catch (e: Exception) {
                if (!closed) emit(tid, "error")
            }
        }

        private fun bind(sock: Socket) {
            socket = sock
            out = sock.getOutputStream()
            emit(tid, "connected")
            readLoop(sock.getInputStream())
        }

        private fun readLoop(input: InputStream) {
            val buf = ByteArray(64 * 1024)
            try {
                while (!closed) {
                    val n = input.read(buf)
                    if (n < 0) break
                    if (n > 0) emit(tid, "data", buf.copyOf(n))
                }
            } catch (_: Exception) {
            } finally {
                if (!closed) emit(tid, "eof")
            }
        }

        fun write(data: ByteArray) {
            try { out?.write(data); out?.flush() } catch (_: Exception) {}
        }

        fun finishSending() {
            // 수신 측은 Dart의 길이 접두사로 완료를 판단한다; 알릴 것이 없다.
        }

        fun close() {
            closed = true
            try { socket?.close() } catch (_: Exception) {}
            try { server?.close() } catch (_: Exception) {}
            networkCallback?.let { cb ->
                try { connectivityManager?.unregisterNetworkCallback(cb) } catch (_: Exception) {}
            }
        }
    }
}
