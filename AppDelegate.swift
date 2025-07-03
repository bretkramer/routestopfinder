//
//  AppDelegate.swift
//  RouteStopFinder
//
//  Created by Bret Kramer on 7/3/25.
//

import Foundation
import UIKit
import GoogleMaps
import GooglePlaces

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        GMSServices.provideAPIKey("AIzaSyALKwJi3EGOjCLZzY13ZUnneMtBMxbAbQ4")
        GMSPlacesClient.provideAPIKey("AIzaSyALKwJi3EGOjCLZzY13ZUnneMtBMxbAbQ4")
        return true
    }

    func resolveShortURL(_ shortURL: String, completion: @escaping (URL?) -> Void) {
        guard let url = URL(string: shortURL) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Allow redirects to be followed automatically
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let finalURL = response?.url {
                completion(finalURL)
            } else {
                completion(nil)
            }
        }
        task.resume()
    }
}
