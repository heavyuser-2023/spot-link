//
//  SpotLinkWakeLog.swift
//  bluetooth_low_energy_darwin (SpotLink fork)
//
//  Diagnostics helper: records why the app came alive so a boot can be
//  attributed to the BLE state-restoration path vs the iBeacon path. This
//  module cannot see the Runner target's BeaconPlugin, so it writes to the
//  same process-wide UserDefaults key ("spotlink.wake.events"). Dart drains
//  the key into ble.log at boot. Bounded so it never grows across relaunches.
//

import Foundation

enum SpotLinkWakeLog {
    static func record(_ reason: String) {
        let key = "spotlink.wake.events"
        let defaults = UserDefaults.standard
        var events = defaults.stringArray(forKey: key) ?? []
        events.append("\(reason) \(ISO8601DateFormatter().string(from: Date()))")
        if events.count > 12 { events.removeFirst(events.count - 12) }
        defaults.set(events, forKey: key)
    }
}
