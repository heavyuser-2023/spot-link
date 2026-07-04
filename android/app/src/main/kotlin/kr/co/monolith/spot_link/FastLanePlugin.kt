package kr.co.monolith.spot_link

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
 * Wi-Fi fast lane for Android via Wi-Fi Direct (Wi-Fi P2P). The receiver
 * creates an autonomous group (acting as a temporary SoftAP / group owner at
 * 192.168.49.1) and advertises its SSID+passphrase over BLE; the sender joins
 * that Wi-Fi via [WifiNetworkSpecifier] and both move the file's bytes over a
 * plain TCP socket. The mesh still negotiates/encrypts/ACKs over BLE.
 *
 * Implements the `spotlink/fastlane` channel contract used by Dart's
 * PlatformFastLane. NOTE: written per the Android APIs but NOT runtime-verified
 * in this build — needs two Android devices to validate on hardware.
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

    // Receiver: create a group, listen on a socket, advertise SSID+pass+ip:port.
    @Suppress("MissingPermission")
    private fun prepareInbound(tid: String, result: MethodChannel.Result) {
        val mgr = p2p
        val ch = p2pChannel
        if (mgr == null || ch == null) { result.success(null); return }
        mgr.createGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                mgr.requestGroupInfo(ch) { group ->
                    if (group == null) { result.success(null); return@requestGroupInfo }
                    // Group owner address is fixed at 192.168.49.1.
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

    // Sender: join the receiver's group SSID as a Wi-Fi client, then dial it.
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
                // Dial the group owner over the joined P2P network.
                t.dial(network, ip, portStr.toInt())
            }
            override fun onUnavailable() {
                emit(tid, "error")
            }
        }
        t.networkCallback = callback
        t.connectivityManager = cm
        cm.requestNetwork(request, callback)
        result.success(true) // connection result arrives via the event stream
    }

    private fun teardown(tid: String) {
        transfers.remove(tid)?.close()
        // Best-effort: remove the P2P group if we created one.
        val mgr = p2p; val ch = p2pChannel
        if (mgr != null && ch != null) {
            mgr.removeGroup(ch, null)
        }
    }

    /** One transfer's socket + reader/writer threads. */
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
            // Receiver completes on the Dart length-prefix; nothing to signal.
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
