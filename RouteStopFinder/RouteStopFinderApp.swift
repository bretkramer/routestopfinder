//
//  RouteStopFinderApp.swift
//  RouteStopFinder
//
//  Created by Bret Kramer on 7/3/25.
//

import SwiftUI

@main
// struct RouteStopFinderApp: App {
//    let persistenceController = PersistenceController.shared

//    var body: some Scene {
//        WindowGroup {
//            ContentView()
//                .environment(\.managedObjectContext, persistenceController.container.viewContext)
//        }
//    }
//}

struct RouteStopFinderApp: App {
    // Register AppDelegate for Google Maps setup
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                } else {
                    ContentView()
                        .onOpenURL { url in
                            print("Received URL: \(url)")
                            // You can add more logic here to handle the URL
                        }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation {
                        showSplash = false
                    }
                }
            }
        }
    }
}
