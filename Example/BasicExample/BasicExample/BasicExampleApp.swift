//
//  BasicExampleApp.swift
//  BasicExample
//
//  Created by Brandon Sneed on 2/23/22.
//

import SwiftUI
import Segment
import SegmentAdobe

@main
struct BasicExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

extension Analytics {
    static var main: Analytics {
        let analytics = Analytics(configuration: Configuration(writeKey: "1Y90gFG3fBWv33PsE5piliJjF6xIOVmV")
                    .flushAt(3)
                    .trackApplicationLifecycleEvents(true))
        analytics.add(plugin: AdobeDestination(appId: "05eee2681a65/8568043f38bd/launch-cb1c6fbb8ece-development"))
        return analytics
    }
}
