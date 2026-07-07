package kr.co.monolith.spot_link

import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
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
        // Must match BeaconPlugin.swift's beaconUUID.
        val BEACON_UUID: UUID = UUID.fromString("7A3B5C4D-1E2F-4A5B-8C9D-0E1F2A3B4C5D")
        private const val APPLE_MANUFACTURER_ID = 0x004C

        // Process-wide advertiser state (deliberately NOT per-engine): the
        // torch must keep burning after the UI engine dies (swipe-kill) —
        // the foreground service keeps the process, and this beacon is what
        // revives nearby swipe-killed iPhones. Static keeps startTx
        // idempotent across engine re-attachments too (no duplicate
        // advertise sets).
        private var advertiser: BluetoothLeAdvertiser? = null
        private var callback: AdvertiseCallback? = null
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
    private fun beaconPayload(): ByteArray {
        val buf = ByteBuffer.allocate(23)
        buf.put(0x02).put(0x15)
        buf.putLong(BEACON_UUID.mostSignificantBits)
        buf.putLong(BEACON_UUID.leastSignificantBits)
        buf.putShort(0) // major
        buf.putShort(0) // minor
        buf.put(0xC5.toByte()) // measured power at 1m (typical)
        return buf.array()
    }

    @Suppress("MissingPermission")
    private fun startTx() {
        if (callback != null) return // already advertising
        val adapter =
            (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
                ?: return
        val adv = adapter.bluetoothLeAdvertiser ?: return
        advertiser = adv
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(false)
            .build()
        val data = AdvertiseData.Builder()
            .addManufacturerData(APPLE_MANUFACTURER_ID, beaconPayload())
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .build()
        val cb = object : AdvertiseCallback() {}
        callback = cb
        try {
            adv.startAdvertising(settings, data, cb)
        } catch (_: Exception) {
            callback = null
        }
    }

    @Suppress("MissingPermission")
    private fun stopTx() {
        val cb = callback ?: return
        callback = null
        try { advertiser?.stopAdvertising(cb) } catch (_: Exception) {}
    }
}
