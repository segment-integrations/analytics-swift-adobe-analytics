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
import AEPAssurance


public class SegmentAdobe: DestinationPlugin {
    public var analytics: Segment.Analytics?
    
    public let timeline = Timeline()
    public let type = PluginType.destination
    public let key = "Adobe Analytics"
    
    private var adobeSettings: SegmentAdobeSettings?
    
    private var contextValues = [String: Any]()
    private var segmentSettings: Settings!
    
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
        
        var trackEvent = event.event
        
        // You can send ecommerce events via either a trackAction or trackState call.
        // Since Segment does not spec sending products on `screen`, we
        // will only support sending this via trackAction
        
        if SegmentAdobe.adobeEcommerceEvents.keys.contains(trackEvent) {
            if let properties = event.properties, let context = event.context , let trackEcommEvent = SegmentAdobe.adobeEcommerceEvents[trackEvent] {
                let mappedProducts = mapProducts(event: trackEcommEvent, properties: properties, context: context, payload: event)
                MobileCore.track(action: trackEcommEvent, data: mappedProducts)
            }
            analytics?.log(message: "Adobe Analytics trackAction - \(trackEvent)")
            return event;
        }
        
        //TODO: Video events
        if SegmentAdobe.adobeVideoEvents.contains(trackEvent) {
            
        }
        
        
        let mappedEvent = mapEventsV2(event: trackEvent) ?? ""
        if mappedEvent != trackEvent {
            analytics?.log(message: "Event must be configured in Adobe and in the EventsV2 setting in Segment before sending.")
            return event
        }
        
        if let properties = event.properties, let context = event.context, let topLevelProperties = extractSEGTopLevelProps(trackEvent: event) {
            let contextData = mapContextValues(properties: properties, context: context, topLevelProps: topLevelProperties)
            MobileCore.track(action: trackEvent, data: contextData)
            analytics?.log(message: "Adobe Analytics trackAction - \(trackEvent)")
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
        
        if ((properties.arrayValue?.count ?? 0) > 0 || (context.arrayValue?.count ?? 0) > 0) && (contextValues.count > 0){
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
        if (properties.arrayValue?.count ?? 0) == 0 {
            return nil
        }
        guard let topLevelProperties = extractSEGTopLevelProps(trackEvent: payload) else { return nil }
        guard let data = mapContextValues(properties: properties, context: context, topLevelProps: topLevelProperties) else { return nil }
        var contextData = data
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
        debugPrint("productIdentifier--", productIdentifier ?? "")
        
        // Fallback to id. Segment's ecommerce v1 Spec'd `id` as the product identifier
        // The setting productIdentifier checks for id, where ecommerce V2
        // is expecting product_id.
        if settingsProductId == "id" {
            productIdentifier = obj["product_id"] as? String ?? obj["id"] as? String ?? ""
        }
        
        if productIdentifier?.count == 0 {
            debugPrint("Product is a required field.")
            return nil
        }
        
        // Adobe expects Price to refer to the total price (unit price x units).
        let quantity = obj["quantity"] as? Int ?? 1
        let price = obj["price"] as? Double ?? 0.0
        let total = price * Double(quantity)
        
        let output = [category, productIdentifier ?? "", "\(quantity)", "\(total)"]
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
                    return events[key] as? String
                }
            }
        }
        return nil
    }
    
    //Video Tracking
    
}

extension SegmentAdobe: VersionedPlugin {
    public static func version() -> String {
        return __destination_version
    }
}

private struct SegmentAdobeSettings: Codable {
    let apiKey: String?
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
    
    static var eventValueConversion: ((_ key: String, _ value: Any) -> Any) = { (key, value) in
        if let valueString = value as? String {
            return valueString
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
        } else {
            return value
        }
    }
}
