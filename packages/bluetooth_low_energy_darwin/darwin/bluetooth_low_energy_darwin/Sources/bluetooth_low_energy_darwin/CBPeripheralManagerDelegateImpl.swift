//
//  CBPeripheralManagerDelegateImpl.swift
//  bluetooth_low_energy_darwin
//
//  Created by 闫守旺 on 2023/10/7.
//

import Foundation
import CoreBluetooth

class CBPeripheralManagerDelegateImpl: NSObject, CBPeripheralManagerDelegate {
    private let mPeripheralManager: PeripheralManagerImpl
    
    init(_ peripheralManager: PeripheralManagerImpl) {
        self.mPeripheralManager = peripheralManager
    }
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        self.mPeripheralManager.didUpdateState(peripheral: peripheral)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        self.mPeripheralManager.didAdd(peripheral: peripheral, service: service, error: error)
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        self.mPeripheralManager.didStartAdvertising(peripheral: peripheral, error: error)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        self.mPeripheralManager.didReceiveRead(peripheral: peripheral, request: request)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        self.mPeripheralManager.didReceiveWrite(peripheral: peripheral, requests: requests)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        self.mPeripheralManager.didSubscribeTo(peripheral: peripheral, central: central, characteristic: characteristic)
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        self.mPeripheralManager.didUnsubscribeFrom(peripheral: peripheral, central: central, characteristic: characteristic)
    }
    
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        self.mPeripheralManager.isReadyToUpdateSubscribers(peripheral: peripheral)
    }
    
    // SpotLink fork: required to opt in to peripheral-manager restoration.
    // The app republishes its service on start, so adopting the restored
    // services here is unnecessary — the callback just needs to exist.
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String : Any]) {
        SpotLinkWakeLog.record("ble-peripheral-restore")
    }
}
