//
//  AdobeDestination.swift
//  AdobeDestination
//
//  Created by Komal Dhingra on 11/22/22.
//

// NOTE: You can see this plugin in use in the DestinationsExample application.
//
// This plugin is NOT SUPPORTED by Segment.  It is here merely as an example,
// and for your convenience should you find it useful.
//

// MIT License
//
// Copyright (c) 2021 Segment
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation
import Segment
import AEPCore
import AEPMedia
import AEPIdentity
import AEPAnalytics


public class SegmentAdobe: DestinationPlugin {
    public var analytics: Segment.Analytics?
    
    public let timeline = Timeline()
    public let type = PluginType.destination
    public let key = "Adobe Analytics"
    
    private var adobeSettings: SegmentAdobeSettings?
    
    private var contextValues = [String: Any]()
    private var segmentSettings: Settings!
    var mediaTracker: MediaTracker!
    
    public init(appId: String) {
        // Enable debug logging
        MobileCore.setLogLevel(.debug)
        
        MobileCore.registerExtensions([Media.self, Analytics.self, Identity.self], {
            // Use the App id assigned to this application via Adobe Launch
            MobileCore.configureWith(appId: appId)
            
        })
    }
    
    public func update(settings: Settings, type: UpdateType) {
        // Skip if you have a singleton and don't want to keep updating via settings.
        guard type == .initial else { return }
        // Grab the settings and assign them for potential later usage.
        // Note: Since integrationSettings is generic, strongly type the variable.
        guard let tempSettings: SegmentAdobeSettings = settings.integrationSettings(forPlugin: self) else { return }
        
        segmentSettings = settings
        
        if let values = settings.integrationSettings(forKey: key)?["contextValues"] as? [String: Any] {
            contextValues = values
        }
        
        adobeSettings = tempSettings
    }
    
    public func identify(event: IdentifyEvent) -> IdentifyEvent? {
        Analytics.setVisitorIdentifier(visitorIdentifier: event.userId ?? "")
        analytics?.log(message: "Adobe identify \(String(describing: event.userId))")
        return event
    }
    
    public func track(event: TrackEvent) -> TrackEvent? {
        
        let trackEvent = event.event
        
        // You can send ecommerce events via either a trackAction or trackState call.
        // Since Segment does not spec sending products on `screen`, we
        // will only support sending this via trackAction
        
        if SegmentAdobe.adobeEcommerceEvents.keys.contains(trackEvent) {
            if let properties = event.properties, let context = event.context , let trackEcommEvent = SegmentAdobe.adobeEcommerceEvents[trackEvent] {
                let mappedProducts = mapProducts(event: trackEcommEvent, properties: properties, context: context, payload: event)
                MobileCore.track(action: trackEcommEvent, data: mappedProducts)
                analytics?.log(message: "Adobe Analytics trackAction - \(trackEvent)")
            }
            return event;
        }
        
        if SegmentAdobe.adobeVideoEvents.contains(trackEvent) {
            for videoEvent in SegmentAdobe.adobeVideoEvents {
                if videoEvent == trackEvent {
                    trackVideoEvents(event: event)
                }
                return event
            }
        }
        
        let mappedEvent = mapEventsV2(event: trackEvent) ?? ""
        if mappedEvent != trackEvent {
            analytics?.log(message: "Event must be configured in Adobe and in the EventsV2 setting in Segment before sending.")
            return event
        }
        
        if let properties = event.properties, let context = event.context, let topLevelProperties = extractSEGTopLevelProps(trackEvent: event) {
            let contextData = mapContextValues(properties: properties, context: context, topLevelProps: topLevelProperties)
            if contextData != nil {
                MobileCore.track(action: trackEvent, data: contextData)
            } else {
                MobileCore.track(action: trackEvent, data: event.properties?.dictionaryValue ?? nil)
            }
            analytics?.log(message: "Adobe Analytics trackAction - \(trackEvent)")
        } else{
            debugPrint(event.properties?.dictionaryValue)
            MobileCore.track(action: trackEvent, data: event.properties?.dictionaryValue ?? nil)
        }
        
        return event
    }
    
    public func screen(event: ScreenEvent) -> ScreenEvent? {
        let topLevelProperties = extractSEGTopLevelProps(screenEvent: event)
        if let prop = event.properties, let context = event.context , let topLevelProps = topLevelProperties {
            let dataDict = mapContextValues(properties: prop, context: context, topLevelProps: topLevelProps)
            debugPrint("dataDict screen ----", dataDict ?? [:])
            MobileCore.track(state: event.name, data: dataDict)
        } else if topLevelProperties?.isEmpty == false {
            MobileCore.track(state: event.name, data: topLevelProperties)
        }
        else{
            MobileCore.track(state: event.name, data: nil)
        }
        analytics?.log(message: "Adobe Analytics trackState - \(String(describing: event.name))")
        return event
    }
    
    public func reset() {
        Analytics.clearQueue()
    }
    
    ///-------------------------
    /// @name Mapping
    ///-------------------------
    
    /**
     All context data variables must be mapped by using processing rules,
     meaning they must be configured as a context variable in Adobe's UI
     and mapped from a Segment Property or from within Payload.Context
     to the configured variable in Adobe.
     
     @param properties Segment  payload.properties
     @param context Segment  payload.context
     @param topLevelProps NSMutableDictionary of extracted top level payload properties
     @return data Dictionary of context data with Adobe key
     **/
    
    private func mapContextValues(properties: JSON, context: JSON, topLevelProps: [String: Any]) -> [String: Any]? {
        debugPrint("contextValues", contextValues)
        if (properties.dictionaryValue?.isEmpty == false || context.dictionaryValue?.isEmpty == false) && contextValues.count > 0 {
            var dataDict = [String: Any]()
            
            for (key,value) in contextValues {
                print("\(key) , \(value)")
                if key.contains(".") {
                    let arrayofKeyComponents = key.components(separatedBy: ".")
                    // We only support the list of predefined nested context keys per our event spec
                    let predefinedContextKeys = ["traits", "app", "device", "library", "os", "network", "screen"]
                    if predefinedContextKeys.contains(arrayofKeyComponents[0]) {
                        var contextTraits = [String: Any]()
                        contextTraits[arrayofKeyComponents[0]] = context
                        let parsedKey = arrayofKeyComponents[1]
                        if !contextTraits.isEmpty && (contextTraits[parsedKey] != nil) {
                            dataDict[contextValues[key] as? String ?? key] = contextTraits[parsedKey]
                            debugPrint("dataDict", dataDict)
                        }
                    }
                }
                
                var payloadLocation = [String: Any]()
                if (properties.dictionaryValue?[key] != nil) {
                    payloadLocation = properties.dictionaryValue ?? [:]
                }
                if (context.dictionaryValue?[key] != nil) {
                    payloadLocation = context.dictionaryValue ?? [:]
                }
                if !payloadLocation.isEmpty {
                    let contextValueKey = contextValues[key] as! String
                    if ((payloadLocation[key]) != nil) == true {
                        dataDict[contextValueKey] = true
                    } else if ((payloadLocation[key]) != nil) == false {
                        dataDict[contextValueKey] = false
                    } else {
                        dataDict[contextValueKey] = payloadLocation[key]
                    }
                }
            }
            // For screen and track calls our core analytics-ios lib exposes these top level properties
            // These properties are extractetd from the  payload using helper methods (extractSEGTopLevelProps)
            let topLevelProperties = ["event", "messageId", "anonymousId", "name"]
            if topLevelProperties.contains(key) && (topLevelProps[key] != nil) {
                dataDict[contextValues[key] as! String] = topLevelProps[key]
                debugPrint("dataDict", dataDict)
            }
            
            if !dataDict.isEmpty{
                return dataDict
            }
        }
        return nil
    }
    
    ///-------------------------
    /// @name Ecommerce Mapping
    ///-------------------------
    
    /**
     Adobe expects products to be passed in with the key `&&products`.
     
     If `&&products` contains multiple products, the end of a product will
     be delimited by a `,`.
     
     Segment will also send in any additional `contextDataVariables` configured
     in Segment settings.
     
     If a product-specific event is triggered, it must also be sent with the
     `&&events` variable. Segment will send in the Segment spec'd Ecommerce
     event as the `&&events` variable.
     
     @param event Event name sent via track
     @param properties Properties sent via track
     @param context Context sent via track
     @return contextData object with &&events and formatted product String in &&products
     **/
    
    
    private func mapProducts(event: String, properties: JSON, context: JSON, payload: TrackEvent) -> [String: Any]? {
        if properties.dictionaryValue?.isEmpty == true {
            return nil
        }
        guard let topLevelProperties = extractSEGTopLevelProps(trackEvent: payload) else { return nil }
        let data = mapContextValues(properties: properties, context: context, topLevelProps: topLevelProperties)
        var contextData: [String: Any] = data ?? [:]
        // If you trigger a product-specific event by using the &&products variable, you must also set that event in the &&events variable.
        // If you do not set that event, it is filtered out during processing.
        contextData["&&events"] = event
        
        var formattedProducts = ""
        // If Products is of type NSArray (ex. Order Completed),
        // we must end each product with a `,` to denote multiple products
        if let products = properties["products"]?.arrayValue {
            if products.count > 0 {
                var count = 0
                for obj in products {
                    guard let obj = obj as? [String: Any] else {
                        return nil
                    }
                    let result = formatProducts(obj: obj)
                    // Catch the case where productIdentifier is nil
                    if result == nil {
                        return nil
                    }
                    formattedProducts = formattedProducts.appending(result ?? "")
                    count = count + 1
                    if (count < products.count) {
                        formattedProducts = formattedProducts.appending(",;")
                    }
                }
            }
        }else{
            formattedProducts = formatProducts(obj: properties.dictionaryValue ?? [:]) ?? ""
        }
        contextData["&&products"] = formattedProducts
        return contextData
    }
    
    /**
     Adobe expects products to formatted as an NSString, delimited with `;`, with values in the following order:
     `"Category;Product;Quantity;Price;eventN=X[|eventN2=X2];eVarN=merch_category[|eVarN2=merch_category2]"`
     
     Product is a required argument, so if this is not present, Segment does not create the
     `&&products` String. This value can be the product name, sku, or productId,
     which is configured via the Segment setting `productIdentifier`.
     
     If the other values in the String are missing, Segment
     will leave the space empty but keep the `;` delimiter to preserve the order
     of the product properties.
     
     `formatProducts` can take in an object from the products array:
     
     @"products" : @[
     @{
     @"product_id" : @"2013294",
     @"category" : @"Games",
     @"name" : @"Monopoly: 3rd Edition",
     @"brand" : @"Hasbros",
     @"price" : @"21.99",
     @"quantity" : @"1"
     }
     ]
     
     And output the following : @"Games;Monopoly: 3rd Edition;1;21.99,;Games;Battleship;2;27.98"
     
     It can also format a product passed in as a top level property, for example
     
     @{
     @"product_id" : @"507f1f77bcf86cd799439011",
     @"sku" : @"G-32",
     @"category" : @"Food",
     @"name" : @"Turkey",
     @"brand" : @"Farmers",
     @"variant" : @"Free Range",
     @"price" : @180.99,
     @"quantity" : @1,
     }
     
     And output the following:  @"Food;G-32;1;180.99"
     
     @param obj Product from the products array
     
     @return Product string representing one product
     **/
    
    private func formatProducts(obj: [String: Any]) -> String? {
        let category = obj["category"] as? String ?? ""
        // The product argument is REQUIRED for Adobe ecommerce events.
        // This value can be 'name', 'sku', or 'id'. Defaults to name
        guard let settingsProductId = segmentSettings.integrationSettings(forKey: key)?["productIdentifier"] as? String else{
            return nil
        }
        var productIdentifier = obj[settingsProductId] as? String
        
        // Fallback to id. Segment's ecommerce v1 Spec'd `id` as the product identifier
        // The setting productIdentifier checks for id, where ecommerce V2
        // is expecting product_id.
        if settingsProductId == "id" {
            productIdentifier = obj["product_id"] as? String ?? obj["id"] as? String ?? ""
        }
        
        if productIdentifier?.isEmpty == true {
            debugPrint("Product is a required field.")
            return nil
        }
        
        // Adobe expects Price to refer to the total price (unit price x units).
        let quantity = obj["quantity"] as? Int ?? 1
        let price = obj["price"] as? Double ?? 0.0
        let total = price * Double(quantity)
        
        var output: [String] = [category, productIdentifier ?? "", "\(quantity)", "\(total)"]
        return output.joined(separator: ";")
    }
    
    private func extractSEGTopLevelProps(screenEvent: ScreenEvent? = nil, trackEvent: TrackEvent? = nil) -> [String: Any]? {
        var topLevelProperties = [String: Any]()
        topLevelProperties["messageId"] = (screenEvent != nil) ? screenEvent?.messageId : trackEvent?.messageId
        topLevelProperties["anonymousId"] = (screenEvent != nil) ? screenEvent?.anonymousId : trackEvent?.anonymousId
        if (screenEvent != nil) {
            topLevelProperties["name"] = screenEvent?.name
        }
        if (trackEvent != nil) {
            topLevelProperties["event"] = trackEvent?.event
        }
        return topLevelProperties
    }
    
    /**
     In order to respect Adobe's event naming convention, Segment
     has a setting eventsV2 to transform Segment events to
     Adobe's convention.
     
     If an event is not configured, Segment will not send the
     event to Adobe.
     
     @param event Event name sent via track
     @return eventV2 Adobe configured event name
     **/
    
    private func mapEventsV2(event: String)-> String? {
        if let events = segmentSettings.integrationSettings(forKey: key)?["eventsV2"] as? [String: Any] {
            for (key,_) in events {
                if key == event {
                    return event
                }
            }
        }
        return nil
    }
    
    //Video Tracking
    
    private func createTrackerConfig(event: TrackEvent) -> MediaTracker {
        
        let properties = event.properties?.dictionaryValue
        var config = [String: Any]()
        
        // Overrides channel configured in the Data Collection UI
        if let channel = properties?["channel"] as? String {
            config[MediaConstants.TrackerConfig.CHANNEL] = channel
        }
        
        // Creates downloaded content tracker
        config[MediaConstants.TrackerConfig.DOWNLOADED_CONTENT] = true

        let tracker = Media.createTrackerWith(config: config)
        
        return tracker
    }
    
    /**
     Event tracking for Adobe Video Events.

     @param payload Payload sent on Segment `track` call
     */
    
    private func trackVideoEvents(event: TrackEvent) {
        
        switch (event.event)  {
            
          case "Video Playback Started":
            mediaTracker = createTrackerConfig(event: event)
            // mediaTracker can return nil if the Adobe required field
            // trackingServer is not properly configured in Segment's UI.
            if (mediaTracker == nil) {
                return
            }
            
            guard let properties = event.properties?.dictionaryValue, let mediaObject = createWithProperties(properties: properties, eventType: "Playback") else {
                return
            }
            
            //Mapping with standard events
            let standardVideoMetadata = mapStandardVideoMetadata(properties: properties, eventType: "Playback")
            
            guard let properties = event.properties, let context = event.context, let topLevelProperties = extractSEGTopLevelProps(trackEvent: event), let contextData = mapContextValues(properties: properties, context: context, topLevelProps: topLevelProperties)  else {
                return
            }
            let convertedContextData: [String: String] = contextData.compactMapValues { "\($0)" }
            var videoMetadata: [String: String] = standardVideoMetadata.compactMapValues { "\($0)" }
            videoMetadata = videoMetadata.merging(convertedContextData) { (current, _) in current }
            debugPrint("videoMetadata", videoMetadata)
            mediaTracker.trackSessionStart(info: mediaObject, metadata: videoMetadata)
            analytics?.log(message: "Media tracks Started")
            return

          case "Video Playback Paused":
            mediaTracker.trackPause()
            analytics?.log(message: "Media tracks Pause")
            return
            
        case "Video Playback Resumed":
            mediaTracker.trackPlay()
            analytics?.log(message: "Media tracks Resumed")
            return
            
        case "Video Playback Completed":
            mediaTracker.trackComplete()
            analytics?.log(message: "Media track Completed")
            mediaTracker.trackSessionEnd()
            analytics?.log(message: "Media track Session End")
            return
            
        case "Video Content Started":
            mediaTracker.trackPlay()
            analytics?.log(message: "trackPlay")
            
            guard let properties = event.properties?.dictionaryValue, let mediaObject = createWithProperties(properties: properties, eventType: "Content") else {
                return
            }
            
            //Mapping with standard events
            let standardVideoMetadata = mapStandardVideoMetadata(properties: properties, eventType: "Content")
            guard let properties = event.properties, let context = event.context, let topLevelProperties = extractSEGTopLevelProps(trackEvent: event), let contextData = mapContextValues(properties: properties, context: context, topLevelProps: topLevelProperties)  else {
                return
            }
            let convertedContextData: [String: String] = contextData.compactMapValues { "\($0)" }
            var videoMetadata: [String: String] = standardVideoMetadata.compactMapValues { "\($0)" }
            videoMetadata = videoMetadata.merging(convertedContextData) { (current, _) in current }
            debugPrint("videoMetadata", videoMetadata)
            mediaTracker.trackEvent(event: MediaEvent.ChapterStart, info: mediaObject, metadata: videoMetadata)
            analytics?.log(message: "MediaEvent Chapter Start")
            return
            
        case "Video Content Completed":
            mediaTracker.trackEvent(event: MediaEvent.ChapterComplete, info: nil, metadata: nil)
            analytics?.log(message: "MediaEvent ChapterComplete")
            return
            
        case "Video Playback Interrupted":
            mediaTracker.trackPause()
            analytics?.log(message: "MediaEvent Interrupted")
            return
            
        case "Video Playback Buffer Started":
            mediaTracker.trackPause()
            mediaTracker.trackEvent(event: MediaEvent.BufferStart, info: nil, metadata: nil)
            analytics?.log(message: "MediaEvent Buffer Started")
            return
            
        case "Video Playback Seek Started":
            mediaTracker.trackPause()
            mediaTracker.trackEvent(event: MediaEvent.SeekStart, info: nil, metadata: nil)
            analytics?.log(message: "MediaEvent Seek Started")
            return
            
        case "Video Playback Buffer Completed":
            let position = event.properties?.dictionaryValue?["position"] as? Double ?? 0
            mediaTracker.trackPlay()
            mediaTracker.updateCurrentPlayhead(time: position)
            mediaTracker.trackEvent(event: MediaEvent.BufferComplete, info: nil, metadata: nil)
            analytics?.log(message: "MediaEvent BufferComplete")
            return
            
        case "Video Playback Seek Completed":
            let position = event.properties?.dictionaryValue?["position"] as? Double ?? 0
            mediaTracker.trackPlay()
            mediaTracker.updateCurrentPlayhead(time: position)
            mediaTracker.trackEvent(event: MediaEvent.SeekComplete, info: nil, metadata: nil)
            analytics?.log(message: "SeekComplete")
            return
            
        case "Video Ad Break Started":
            guard let properties = event.properties?.dictionaryValue, let mediaObject = createWithProperties(properties: properties, eventType: "Ad Break") else {
                return
            }
            mediaTracker.trackEvent(event: MediaEvent.AdBreakStart, info: mediaObject, metadata: nil)
            analytics?.log(message: "MediaEvent AdBreakStart")
            return
            
        case "Video Ad Break Completed":
            mediaTracker.trackEvent(event: MediaEvent.AdBreakComplete, info: nil, metadata: nil)
            analytics?.log(message: "MediaEvent AdBreakComplete")
            return
            
        case "Video Ad Started":
            guard let properties = event.properties?.dictionaryValue, let mediaObject = createWithProperties(properties: properties, eventType: "Ad") else {
                return
            }
            //Mapping with standard events
            let standardVideoMetadata = mapStandardVideoMetadata(properties: properties, eventType: "Ad")
            guard let properties = event.properties, let context = event.context, let topLevelProperties = extractSEGTopLevelProps(trackEvent: event), let contextData = mapContextValues(properties: properties, context: context, topLevelProps: topLevelProperties)  else {
                return
            }
            let convertedContextData: [String: String] = contextData.compactMapValues { "\($0)" }
            var videoMetadata: [String: String] = standardVideoMetadata.compactMapValues { "\($0)" }
            videoMetadata = videoMetadata.merging(convertedContextData) { (current, _) in current }
            debugPrint("videoMetadata", videoMetadata)
            mediaTracker.trackEvent(event: MediaEvent.AdStart, info: mediaObject, metadata: videoMetadata)
            analytics?.log(message: "MediaEvent AdStart")
          return
            
        case "Video Ad Skipped":
            mediaTracker.trackEvent(event: MediaEvent.AdSkip, info: nil, metadata: nil)
            analytics?.log(message: "MediaEvent AdSkip")
            return
            
        case "Video Ad Completed":
            mediaTracker.trackEvent(event: MediaEvent.AdComplete, info: nil, metadata: nil)
            analytics?.log(message: "MediaEvent AdComplete")
            return
            
        case "Video Quality Updated":
            guard let properties = event.properties, let context = event.context, let topLevelProperties = extractSEGTopLevelProps(trackEvent: event) else { return }
            let contextData = mapContextValues(properties: properties, context: context, topLevelProps: topLevelProperties)
            let bitrate = contextData?["bitrate"] as? Double ?? 0
            let startupTime = contextData?["startup_time"] as? Double ?? 0
            let fps = contextData?["fps"] as? Double ?? 0
            let droppedFrames = contextData?["dropped_frames"] as? Double ?? 0
            guard let qoeObject = Media.createQoEObjectWith(bitrate: bitrate, startupTime: startupTime, fps: fps, droppedFrames: droppedFrames) else { return }
            mediaTracker.updateQoEObject(qoe: qoeObject)
            return
            
          default:
            break
        }
    }
    
    private func createWithProperties(properties: [String: Any], eventType: String) -> [String: Any]? {
        let videoName = properties["title"] as? String ?? ""
        let mediaId = properties["content_asset_id"] as? String ?? ""
        let length = properties["total_length"] as? Double ?? 0
        let adId = properties["asset_id"] as? String ?? ""
        let startTime = properties["start_time"] as? Double ?? 0
        let position = properties["indexPosition"] as? Int ?? 0
        
        // Adobe also has a third type: linear, which we have chosen
        // to omit as it does not conform to Segment's Video spec
        
        let isLivestream = properties["livestream"] as? Bool ?? false
        
        var streamType = MediaConstants.StreamType.VOD
        
        if isLivestream {
            streamType = MediaConstants.StreamType.LIVE
        }
        
        if eventType == "Playback" {
            return Media.createMediaObjectWith(name: videoName, id: mediaId, length: length, streamType: streamType, mediaType: MediaType.Video)
            
        } else if eventType == "Content" {
            return Media.createChapterObjectWith(name: videoName, position: position, length: length, startTime: startTime)
        } else if eventType == "Ad Break" {
            return Media.createAdBreakObjectWith(name: videoName, position: position, startTime: startTime)
        } else if eventType == "Ad" {
            return Media.createAdObjectWith(name: videoName, id: adId, position: position, length: length)
        } else {
            analytics?.log(message: "Event type not passed through.")
        }
        return nil
    }
    
    /**
     Adobe has standard video metadata to pass in on
     Segment's Video Playback events.
     
     @param properties Properties passed in on Segment `track`
     @return A dictionary of mapped Standard Video metadata
     */
    
    private func mapStandardVideoMetadata(properties: [String: Any], eventType: String) -> [String: Any] {
        
        let videoMetadata: [String: Any] = [
            "asset_id" : MediaConstants.VideoMetadataKeys.ASSET_ID,
            "program" : MediaConstants.VideoMetadataKeys.SHOW,
            "season" : MediaConstants.VideoMetadataKeys.SEASON,
            "episode" : MediaConstants.VideoMetadataKeys.EPISODE,
            "genre" : MediaConstants.VideoMetadataKeys.GENRE,
            "channel" : MediaConstants.VideoMetadataKeys.NETWORK,
            "airdate" : MediaConstants.VideoMetadataKeys.FIRST_AIR_DATE,
        ]
        
        var standardVideoMetadata = [String: Any]()
        
        for (key, _) in videoMetadata {
            if (properties[key] != nil) {
                let videoMetadataKey = videoMetadata[key] as! String
                standardVideoMetadata[videoMetadataKey] = properties[key]
            }
        }
        // Segment's publisher property exists on the content and ad level. Adobe
        // needs to interpret this either as and Advertiser (ad events) or Originator (content events)
        
        let publisher = properties["publisher"] as? String
        
        if eventType == "Ad" || eventType == "Ad Break" && publisher?.isEmpty == false {
            standardVideoMetadata[MediaConstants.AdMetadataKeys.ADVERTISER] = properties["publisher"]
        } else if eventType == "Content" && publisher?.isEmpty == false {
            standardVideoMetadata[MediaConstants.VideoMetadataKeys.ORIGINATOR] = properties["publisher"]
        }
        
        // Adobe also has a third type: linear, which we have chosen
        // to omit as it does not conform to Segment's Video spec
        let isLivestream = properties["livestream"] as? Bool
        
        if isLivestream == true {
            standardVideoMetadata[MediaConstants.VideoMetadataKeys.STREAM_FORMAT] = MediaConstants.StreamType.LIVE
        } else{
            standardVideoMetadata[MediaConstants.VideoMetadataKeys.STREAM_FORMAT] = MediaConstants.StreamType.VOD
        }
        
        return standardVideoMetadata
    }
}

extension SegmentAdobe: VersionedPlugin {
    public static func version() -> String {
        return __destination_version
    }
}

private struct SegmentAdobeSettings: Codable {
    let apiKey: String?
    let ssl: Bool?
}

private extension SegmentAdobe {
    
    static var adobeEcommerceEvents = ["Product Added": "scAdd",
                                       "Product Removed": "scRemove",
                                       "Cart Viewed": "scView",
                                       "Checkout Started": "scCheckout",
                                       "Order Completed": "purchase",
                                       "Product Viewed": "prodView"]
    
    static var adobeVideoEvents = ["Video Playback Started",
                                   "Video Playback Paused",
                                   "Video Playback Interrupted",
                                   "Video Playback Buffer Started",
                                   "Video Playback Buffer Completed",
                                   "Video Playback Seek Started",
                                   "Video Playback Seek Completed",
                                   "Video Playback Resumed",
                                   "Video Playback Completed",
                                   "Video Content Started",
                                   "Video Content Completed",
                                   "Video Ad Break Started",   // not spec'd
                                   "Video Ad Break Completed", // not spec'd
                                   "Video Ad Started",
                                   "Video Ad Skipped", // not spec'd
                                   "Video Ad Completed",
                                   "Video Quality Updated"]
    
}

