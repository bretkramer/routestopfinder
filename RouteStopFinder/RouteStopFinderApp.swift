//
//  RouteStopFinderApp.swift
//  RouteStopFinder
//
//  Created by Bret Kramer on 7/3/25.
//

import SwiftUI

@main
struct RouteStopFinderApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
