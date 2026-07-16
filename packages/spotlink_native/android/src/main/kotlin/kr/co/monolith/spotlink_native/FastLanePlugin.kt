package kr.co.monolith.spotlink_native

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
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
    private val port = 8988

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
                val ok = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                    context.packageManager
                        .hasSystemFeature("android.hardware.wifi.direct")
                result.success(if (ok) listOf("wifiDirect") else emptyList<String>())
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

    // 수신 측: 그룹을 생성하고, 소켓에서 대기하며, SSID+pass+ip:port를 광고한다.
    @Suppress("MissingPermission")
    private fun prepareInbound(tid: String, result: MethodChannel.Result) {
        val mgr = p2p
        val ch = p2pChannel
        if (mgr == null || ch == null) { result.success(null); return }
        mgr.createGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                mgr.requestGroupInfo(ch) { group ->
                    if (group == null) { result.success(null); return@requestGroupInfo }
                    // 그룹 오너 주소는 192.168.49.1로 고정되어 있다.
                    val ownerIp = "192.168.49.1"
                    val t = Transfer(tid)
                    transfers[tid] = t
                    t.listen(port)
                    val blob = "${group.networkName}\n${group.passphrase}\n$ownerIp\n$port"
                        .toByteArray(Charsets.UTF_8)
                    result.success(blob)
                }
            }
            override fun onFailure(reason: Int) { result.success(null) }
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

        fun listen(port: Int) = thread {
            try {
                val ss = ServerSocket(port)
                server = ss
                val sock = ss.accept()
                bind(sock)
            } catch (e: Exception) {
                if (!closed) emit(tid, "error")
            }
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
