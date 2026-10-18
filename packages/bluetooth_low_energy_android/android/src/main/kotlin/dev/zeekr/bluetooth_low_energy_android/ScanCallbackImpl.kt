package dev.zeekr.bluetooth_low_energy_android

import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult

class ScanCallbackImpl(manager: CentralManagerImpl) : ScanCallback() {
    private val mManager: CentralManagerImpl

    init {
        mManager = manager
    }

    override fun onScanFailed(errorCode: Int) {
        super.onScanFailed(errorCode)
        mManager.onScanFailed(errorCode)
    }

    override fun onScanResult(callbackType: Int, result: ScanResult) {
        super.onScanResult(callbackType, result)
        mManager.onScanResult(result)
    }

    override fun onBatchScanResults(results: MutableList<ScanResult>) {
        super.onBatchScanResults(results)
        for (result in results) {
            mManager.onScanResult(result)
        }
    }
}