package kr.co.monolith.spotlink_native

import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.UUID

/**
 * SpotLink wake-beacon transmitter. Android can advertise an iBeacon frame in
 * the background indefinitely, so every Android node doubles as a "wake
 * torch": iPhones monitoring the SpotLink beacon region get relaunched by
 * CoreLocation when we come near — even if the user swipe-killed them.
 *
 * Same channel contract as iOS BeaconPlugin.swift (`spotlink/beacon`), but
 * only the TX half applies here (Android needs no beacon-wake RX: the
 * foreground service already keeps the mesh alive).
 */
class BeaconPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        // Must match BeaconPlugin.swift's beaconUUIDs (index 0 = original).
        // We rotate the transmitted UUID so an iPhone stuck "inside" one
        // region still gets a fresh ENTER when we light a different one — see
        // the long comment in BeaconPlugin.swift.
        val BEACON_UUIDS: List<UUID> = listOf(
            UUID.fromString("7A3B5C4D-1E2F-4A5B-8C9D-0E1F2A3B4C5D"),
            UUID.fromString("7A3B5C4D-1E2F-4A5B-8C9D-0E1F2A3B4C5E"),
            UUID.fromString("7A3B5C4D-1E2F-4A5B-8C9D-0E1F2A3B4C5F"),
        )
        private const val APPLE_MANUFACTURER_ID = 0x004C
        private const val ROTATE_MS = 18_000L

        // Process-wide advertiser state (deliberately NOT per-engine): the
        // torch must keep burning after the UI engine dies (swipe-kill) —
        // the foreground service keeps the process, and this beacon is what
        // revives nearby swipe-killed iPhones. Static keeps startTx
        // idempotent across engine re-attachments too (no duplicate
        // advertise sets).
        private var advertiser: BluetoothLeAdvertiser? = null
        private var callback: AdvertiseCallback? = null
        private var txIndex = 0
        private var rotateHandler: Handler? = null
        private var rotateRunnable: Runnable? = null
    }

    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        MethodChannel(binding.binaryMessenger, "spotlink/beacon")
            .setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Keep advertising: engine death (activity closed) is not process
        // death, and the beacon belongs to the process.
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startTx" -> { startTx(); result.success(null) }
            "stopTx" -> { stopTx(); result.success(null) }
            "status" -> result.success(
                mapOf("auth" to "always", "monitoring" to false))
            // iOS-only RX methods are no-ops here.
            "requestAlways" -> result.success(null)
            "enableMonitoring" -> result.success(false)
            "disableMonitoring" -> result.success(null)
            else -> result.notImplemented()
        }
    }

    /** iBeacon layout inside Apple's manufacturer data:
     *  type(0x02) len(0x15) uuid(16B) major(2B) minor(2B) txPower(1B). */
    private fun beaconPayload(uuid: UUID): ByteArray {
        val buf = ByteBuffer.allocate(23)
        buf.put(0x02).put(0x15)
        buf.putLong(uuid.mostSignificantBits)
        buf.putLong(uuid.leastSignificantBits)
        buf.putShort(0) // major
        buf.putShort(0) // minor
        buf.put(0xC5.toByte()) // measured power at 1m (typical)
        return buf.array()
    }

    @Suppress("MissingPermission")
    private fun startTx() {
        startAdvertisingCurrent()
        // Arm the rotation EVEN IF the initial start failed (Bluetooth off /
        // no advertiser yet): each 18s tick calls restartAdvertising →
        // startAdvertisingCurrent, so the rotation doubles as the retry loop
        // that relights the torch once the adapter comes back. (Previously a
        // BT-off boot left the torch dark until a full app/service restart.)
        if (BEACON_UUIDS.size > 1 && rotateRunnable == null) {
            val h = Handler(Looper.getMainLooper())
            rotateHandler = h
            val r = object : Runnable {
                override fun run() {
                    txIndex = (txIndex + 1) % BEACON_UUIDS.size
                    restartAdvertising()
                    h.postDelayed(this, ROTATE_MS)
                }
            }
            rotateRunnable = r
            h.postDelayed(r, ROTATE_MS)
        }
    }

    @Suppress("MissingPermission")
    private fun startAdvertisingCurrent() {
        if (callback != null) return // already advertising
        val adapter =
            (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
                ?: return
        val adv = adapter.bluetoothLeAdvertiser ?: return
        advertiser = adv
        // BALANCED (~250ms interval) + HIGH power: an iPhone's screen-off
        // region monitoring needs to actually HEAR the beacon to fire the
        // wake — LOW_POWER's ~1s interval at MEDIUM power made detection
        // slow and short-ranged (observed: sluggish cross-platform wakes).
        // This is the wake torch, reachability is its whole job.
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(false)
            .build()
        val data = AdvertiseData.Builder()
            .addManufacturerData(APPLE_MANUFACTURER_ID, beaconPayload(BEACON_UUIDS[txIndex]))
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .build()
        // onStartFailure matters: an ASYNC failure (e.g. TOO_MANY_ADVERTISERS
        // while the mesh advert set is up) used to leave `callback` set — we
        // believed the torch was lit while nothing was on the air. Clearing it
        // lets the next rotation tick's restartAdvertising retry cleanly.
        val cb = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                if (callback === this) callback = null
            }
        }
        callback = cb
        try {
            adv.startAdvertising(settings, data, cb)
        } catch (_: Exception) {
            callback = null
        }
    }

    /** Swap the advertised region to BEACON_UUIDS[txIndex]. */
    @Suppress("MissingPermission")
    private fun restartAdvertising() {
        val cb = callback
        if (cb != null) {
            callback = null
            try { advertiser?.stopAdvertising(cb) } catch (_: Exception) {}
        }
        startAdvertisingCurrent()
    }

    @Suppress("MissingPermission")
    private fun stopTx() {
        rotateRunnable?.let { rotateHandler?.removeCallbacks(it) }
        rotateRunnable = null
        rotateHandler = null
        val cb = callback ?: return
        callback = null
        try { advertiser?.stopAdvertising(cb) } catch (_: Exception) {}
    }
}
