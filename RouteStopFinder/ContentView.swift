//
//  ContentView.swift
//  RouteStopFinder
//
//  Created by Bret Kramer on 7/3/25.
//

import SwiftUI
import CoreLocation
import GoogleMaps

// Move these types to top-level so all views can access them

enum SearchMode: String, CaseIterable, Identifiable {
    case link = "Paste Link"
    case manual = "Search by Name/Address"
    var id: String { self.rawValue }
}

struct AutocompleteSuggestion: Identifiable {
    let id = UUID()
    let description: String
    let placeID: String
}

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var location: CLLocationCoordinate2D?
    override init() {
        super.init()
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last?.coordinate
    }
}

struct PlaceResult: Identifiable {
    let id = UUID()
    let name: String
    let location: CLLocationCoordinate2D
    let distanceFromUser: Double
    let address: String?
    let placeID: String?
}

struct ContentView: View {
    @State private var pastedLink: String = ""
    @State private var searchMode: SearchMode = .manual
    @State private var manualDestination: String = ""
    @State private var autocompleteSuggestions: [AutocompleteSuggestion] = []
    @State private var destinationCoordinate: CLLocationCoordinate2D?
    @State private var userLocation: CLLocationCoordinate2D?
    @State private var selectedPlaceType: String = "gas_station"
    @State private var searchStartMiles: Double = 100.0
    @State private var searchEndMiles: Double = 150.0
    @State private var searchStartMinutes: Double = 0.0
    @State private var searchEndMinutes: Double = 60.0
    @State private var routePolyline: String?
    @State private var placeResults: [(PlaceResult, Int)] = [] // (Place, addedTime)
    @State private var sortMode: SortMode = .distance
    @State private var selectedStop: PlaceResult? = nil
    @State private var filterText: String = ""
    @State private var rangeMode: RangeMode = .distance
    @State private var showOrderAlert: Bool = false
    @State private var addressToCopy: String = ""
    @State private var alertMessage: String = ""
    @State private var searchEntireRoute: Bool = false
    @State private var showHelp: Bool = false
    // Track if user has manually changed the range
    @State private var userChangedRange: Bool = false
    // Track last location/destination used for defaults
    @State private var lastDefaultOrigin: CLLocationCoordinate2D?
    @State private var lastDefaultDestination: CLLocationCoordinate2D?
    @State private var selectedTab: Int = 0

    // MARK: - Geocoding
    func geocodeAddress(_ address: String, completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        let apiKey = "AIzaSyALKwJi3EGOjCLZzY13ZUnneMtBMxbAbQ4" // Updated API key
        let addressEncoded = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://maps.googleapis.com/maps/api/geocode/json?address=\(addressEncoded)&key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let data = data {
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("Geocoding API response: \(jsonString)")
                }
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let geometry = results.first?["geometry"] as? [String: Any],
                  let location = geometry["location"] as? [String: Any],
                  let lat = location["lat"] as? CLLocationDegrees,
                  let lng = location["lng"] as? CLLocationDegrees else {
                completion(nil)
                return
            }
            completion(CLLocationCoordinate2D(latitude: lat, longitude: lng))
        }
        task.resume()
    }

    // MARK: - User Location
    @StateObject private var locationManager = LocationManager()

    // Function to resolve Google Maps short URL
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

    // MARK: - Directions API
    func fetchRoutePolyline(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, completion: @escaping (String?) -> Void) {
        let apiKey = "AIzaSyALKwJi3EGOjCLZzY13ZUnneMtBMxbAbQ4"
        let originStr = "\(origin.latitude),\(origin.longitude)"
        let destStr = "\(destination.latitude),\(destination.longitude)"
        let urlString = "https://maps.googleapis.com/maps/api/directions/json?origin=\(originStr)&destination=\(destStr)&key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let data = data, let jsonString = String(data: data, encoding: .utf8) {
                print("Directions API response: \(jsonString)")
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let routes = json["routes"] as? [[String: Any]],
                  let firstRoute = routes.first,
                  let overviewPolyline = firstRoute["overview_polyline"] as? [String: Any],
                  let polyline = overviewPolyline["points"] as? String else {
                completion(nil)
                return
            }
            completion(polyline)
        }
        task.resume()
    }

    // MARK: - Polyline Decoding
    func decodePolyline(_ polyline: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        let data = polyline.data(using: .utf8) ?? Data()
        let length = data.count
        var index = 0
        var lat: Int32 = 0
        var lng: Int32 = 0
        while index < length {
            var b: UInt8
            var shift: UInt32 = 0
            var result: Int32 = 0
            repeat {
                b = data[index] - 63
                index += 1
                result |= Int32(b & 0x1F) << shift
                shift += 5
            } while b >= 0x20
            let dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1))
            lat += dlat
            shift = 0
            result = 0
            repeat {
                b = data[index] - 63
                index += 1
                result |= Int32(b & 0x1F) << shift
                shift += 5
            } while b >= 0x20
            let dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1))
            lng += dlng
            let coord = CLLocationCoordinate2D(latitude: Double(lat) * 1e-5, longitude: Double(lng) * 1e-5)
            coordinates.append(coord)
        }
        return coordinates
    }

    // MARK: - Distance Calculation
    func haversineDistance(_ coord1: CLLocationCoordinate2D, _ coord2: CLLocationCoordinate2D) -> Double {
        let R = 6371.0 // Earth radius in km
        let dLat = (coord2.latitude - coord1.latitude) * .pi / 180
        let dLon = (coord2.longitude - coord1.longitude) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2) + cos(coord1.latitude * .pi / 180) * cos(coord2.latitude * .pi / 180) * sin(dLon/2) * sin(dLon/2)
        let c = 2 * atan2(sqrt(a), sqrt(1-a))
        return R * c
    }

    // MARK: - Places API
    func searchPlaces(near coordinate: CLLocationCoordinate2D, type: String, completion: @escaping ([PlaceResult]) -> Void) {
        let apiKey = "AIzaSyALKwJi3EGOjCLZzY13ZUnneMtBMxbAbQ4"
        let locationStr = "\(coordinate.latitude),\(coordinate.longitude)"
        let radius = 5000 // meters (5km)
        
        var urlString: String
        if type == "any" {
            // Use text search for "any" category - will use filter text if available
            let searchQuery = filterText.isEmpty ? "restaurant" : filterText // fallback to restaurant if no filter
            let encodedQuery = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchQuery
            urlString = "https://maps.googleapis.com/maps/api/place/textsearch/json?query=\(encodedQuery)&location=\(locationStr)&radius=\(radius)&key=\(apiKey)"
        } else {
            // Use nearby search for specific categories
            urlString = "https://maps.googleapis.com/maps/api/place/nearbysearch/json?location=\(locationStr)&radius=\(radius)&type=\(type)&key=\(apiKey)"
        }
        
        guard let url = URL(string: urlString) else {
            completion([])
            return
        }
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            var results: [PlaceResult] = []
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let places = json["results"] as? [[String: Any]] else {
                completion([])
                return
            }
            for place in places {
                if let name = place["name"] as? String,
                   let geometry = place["geometry"] as? [String: Any],
                   let loc = geometry["location"] as? [String: Any],
                   let lat = loc["lat"] as? CLLocationDegrees,
                   let lng = loc["lng"] as? CLLocationDegrees {
                    let placeCoord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                    let distance = userLocation.map { haversineDistance($0, placeCoord) } ?? 0.0
                    let address = place["vicinity"] as? String ?? place["formatted_address"] as? String
                    let placeID = place["place_id"] as? String
                    results.append(PlaceResult(name: name, location: placeCoord, distanceFromUser: distance, address: address, placeID: placeID))
                }
            }
            completion(results)
        }
        task.resume()
    }

    var body: some View {
        NavigationView {
            TabView(selection: $selectedTab) {
                // Tab 1: Destination
                DestinationTabView(
                    searchMode: $searchMode,
                    pastedLink: $pastedLink,
                    manualDestination: $manualDestination,
                    autocompleteSuggestions: $autocompleteSuggestions,
                    destinationCoordinate: $destinationCoordinate,
                    userLocation: $userLocation,
                    locationManager: locationManager,
                    geocodeAddress: geocodeAddress,
                    resolveShortURL: resolveShortURL,
                    fetchAutocompleteSuggestions: fetchAutocompleteSuggestions,
                    fetchPlaceDetails: fetchPlaceDetails,
                    selectedTab: $selectedTab
                )
                .tabItem {
                    Image(systemName: "mappin.circle")
                    Text("Destination")
                }
                .tag(0)
                
                // Tab 2: Search Settings
                SearchSettingsTabView(
                    selectedPlaceType: $selectedPlaceType,
                    filterText: $filterText,
                    rangeMode: $rangeMode,
                    searchStartMiles: $searchStartMiles,
                    searchEndMiles: $searchEndMiles,
                    searchStartMinutes: $searchStartMinutes,
                    searchEndMinutes: $searchEndMinutes,
                    searchEntireRoute: $searchEntireRoute,
                    userChangedRange: $userChangedRange,
                    userLocation: userLocation,
                    destinationCoordinate: destinationCoordinate,
                    placeResults: $placeResults,
                    routePolyline: $routePolyline,
                    fetchRoutePolyline: fetchRoutePolyline,
                    decodePolyline: decodePolyline,
                    haversineDistance: haversineDistance,
                    searchPlaces: searchPlaces,
                    selectedTab: $selectedTab // pass binding
                )
                .tabItem {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                }
                .tag(1)
                
                // Tab 3: Results
                ResultsTabView(
                    placeResults: placeResults,
                    sortMode: $sortMode,
                    filterText: filterText,
                    selectedStop: $selectedStop,
                    showOrderAlert: $showOrderAlert,
                    addressToCopy: $addressToCopy,
                    alertMessage: $alertMessage,
                    openInGoogleMaps: openInGoogleMaps,
                    orderURLForPlace: orderURLForPlace,
                    tryOpenOrderURL: tryOpenOrderURL,
                    userLocation: userLocation,
                    destinationCoordinate: destinationCoordinate,
                    routePolyline: routePolyline
                )
                .tabItem {
                    Image(systemName: "list.bullet")
                    Text("Results")
                }
                .tag(2)
            }
            .navigationTitle("RouteStopFinder")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showHelp = true }) {
                        Image(systemName: "questionmark.circle")
                            .imageScale(.large)
                    }
                }
            }
            .sheet(isPresented: $showHelp) {
                HelpView()
            }
            .onAppear {
                setDefaultRangeIfNeeded()
            }
            .onChange(of: userLocation?.latitude) { _, _ in setDefaultRangeIfNeeded() }
            .onChange(of: destinationCoordinate?.latitude) { _, _ in setDefaultRangeIfNeeded() }
        }
        .hideKeyboardOnTap()
        .alert(isPresented: $showOrderAlert) {
            Alert(
                title: Text("Could Not Open App or Website"),
                message: Text(alertMessage),
                primaryButton: .default(Text("Copy Address")) {
                    UIPasteboard.general.string = addressToCopy
                },
                secondaryButton: .cancel()
            )
        }
    }

    // Computed property for sorted results
    var sortedPlaceResults: [(PlaceResult, Int)] {
        switch sortMode {
        case .distance:
            return placeResults.sorted { $0.0.distanceFromUser < $1.0.distanceFromUser }
        case .addedTime:
            return placeResults.sorted { 
                if $0.1 == $1.1 {
                    // If added times are equal, sort by distance (closer first)
                    return $0.0.distanceFromUser < $1.0.distanceFromUser
                }
                return $0.1 < $1.1 
            }
        }
    }

    // Computed property for filtered and sorted results
    var filteredPlaceResults: [(PlaceResult, Int)] {
        let lowercasedFilter = filterText.lowercased()
        return sortedPlaceResults.filter { place, _ in
            filterText.isEmpty || place.name.lowercased().contains(lowercasedFilter)
        }
    }

    // Open Google Maps with selected stop as waypoint
    func openInGoogleMaps(stop: PlaceResult) {
        guard let userLoc = userLocation, let dest = destinationCoordinate else { return }
        let saddr = "\(userLoc.latitude),\(userLoc.longitude)"
        let daddr = "\(dest.latitude),\(dest.longitude)"
        // Always use address (never place_id) for both app and web URLs
        let waypoint: String
        if let address = stop.address, !address.isEmpty {
            waypoint = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? address
        } else if !stop.name.isEmpty {
            waypoint = stop.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? stop.name
        } else {
            waypoint = "\(stop.location.latitude),\(stop.location.longitude)"
        }
        // Try to use the Google Maps app if installed
        if let url = URL(string: "comgooglemaps://?saddr=\(saddr)&daddr=\(waypoint)+to:\(daddr)&directionsmode=driving"), UIApplication.shared.canOpenURL(url) {
            print("Opening Google Maps app with URL: \(url)")
            UIApplication.shared.open(url)
        } else if let webUrl = URL(string: "https://www.google.com/maps/dir/?api=1&origin=\(saddr)&destination=\(daddr)&waypoints=\(waypoint)") {
            print("Opening Google Maps web with URL: \(webUrl)")
            UIApplication.shared.open(webUrl)
        }
    }

    // Returns a URL to open the fast food app or website for ordering, if supported
    func orderURLForPlace(_ place: PlaceResult) -> URL? {
        let name = place.name.lowercased()
        let address = place.address?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        // Chick-fil-A
        if name.contains("chick-fil-a") || name.contains("chick fil a") {
            return URL(string: "https://apps.apple.com/us/app/chick-fil-a/id488818252")
        }
        // Wendy's
        if name.contains("wendy's") || name.contains("wendys") {
            if let url = URL(string: "wendys://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/wendys/id540518599")
            }
        }
        // Taco Bell
        if name.contains("taco bell") {
            if let url = URL(string: "tacobell://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/taco-bell/id497387361")
            }
        }
        // Whataburger
        if name.contains("whataburger") {
            if let url = URL(string: "whataburger://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/whataburger/id899745870")
            }
        }
        // Starbucks
        if name.contains("starbucks") {
            if let url = URL(string: "starbucks://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/starbucks/id331177714")
            }
        }
        // McDonald's
        if name.contains("mcdonald") || name.contains("mc donald") {
            if let url = URL(string: "mcdonalds://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/mcdonalds/id922103212")
            }
        }
        // Burger King
        if name.contains("burger king") {
            if let url = URL(string: "bk://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/burger-king/id638323895")
            }
        }
        // Subway
        if name.contains("subway") {
            return URL(string: "https://apps.apple.com/us/app/subway/id414108241")
        }
        // Dunkin'
        if name.contains("dunkin") {
            if let url = URL(string: "dunkin://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/dunkin/id333193622")
            }
        }
        // Domino's
        if name.contains("domino's") || name.contains("dominos") {
            if let url = URL(string: "dominos://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/dominos-pizza/id436491861")
            }
        }
        // Pizza Hut
        if name.contains("pizza hut") {
            if let url = URL(string: "pizzahut://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/pizza-hut/id321560858")
            }
        }
        // KFC
        if name.contains("kfc") {
            if let url = URL(string: "kfc://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/kfc/id915824379")
            }
        }
        // Popeyes
        if name.contains("popeyes") {
            return URL(string: "https://apps.apple.com/us/app/popeyes/id1437678659")
        }
        // Sonic Drive-In
        if name.contains("sonic") {
            if let url = URL(string: "sonic://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/sonic/id355989169")
            }
        }
        // Panera Bread
        if name.contains("panera") {
            if let url = URL(string: "panera://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/panera-bread/id469881039")
            }
        }
        // Arby's
        if name.contains("arby's") || name.contains("arbys") {
            return URL(string: "https://apps.apple.com/us/app/arbys/id1003759022")
        }
        // Jack in the Box
        if name.contains("jack in the box") {
            if let url = URL(string: "jackinthebox://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/jack-in-the-box/id370139302")
            }
        }
        // Little Caesars
        if name.contains("little caesars") {
            return URL(string: "https://apps.apple.com/us/app/little-caesars/id479375789")
        }
        // Chipotle
        if name.contains("chipotle") {
            if let url = URL(string: "chipotle://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/chipotle/id327228455")
            }
        }
        // Dairy Queen
        if name.contains("dairy queen") {
            return URL(string: "https://apps.apple.com/us/app/dairy-queen/id584183427")
        }
        // Jimmy John's
        if name.contains("jimmy john's") || name.contains("jimmy johns") {
            if let url = URL(string: "jimmyjohns://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/jimmy-johns/id434413477")
            }
        }
        // Jersey Mike's
        if name.contains("jersey mike's") || name.contains("jersey mikes") {
            if let url = URL(string: "jerseymikes://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/jersey-mikes/id653319142")
            }
        }
        // Raising Cane's
        if name.contains("raising cane") {
            return URL(string: "https://apps.apple.com/us/app/raising-canes/id1472979382")
        }
        // Culver's
        if name.contains("culver") {
            return URL(string: "https://apps.apple.com/us/app/culvers/id1115120118")
        }
        // In-N-Out Burger
        if name.contains("in-n-out") || name.contains("in n out") {
            return URL(string: "https://apps.apple.com/us/app/in-n-out/id402983682")
        }
        // Carl's Jr.
        if name.contains("carl's jr") || name.contains("carls jr") {
            if let url = URL(string: "carlsjr://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/carls-jr/id430127939")
            }
        }
        // Hardee's
        if name.contains("hardee") {
            if let url = URL(string: "hardees://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/hardees/id430127939")
            }
        }
        // Krispy Kreme
        if name.contains("krispy kreme") {
            if let url = URL(string: "krispykreme://"), UIApplication.shared.canOpenURL(url) {
                return url
            } else {
                return URL(string: "https://apps.apple.com/us/app/krispy-kreme/id529405893")
            }
        }
        return nil
    }

    // Try to open the order URL, show alert if it fails
    func tryOpenOrderURL(_ url: URL, for place: PlaceResult) {
        // Always copy the address to the clipboard before opening
        let address = place.address ?? ""
        UIPasteboard.general.string = address
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                // Prepare alert with address to copy
                addressToCopy = address
                alertMessage = "Failed to open ordering app or website. This app may not be available in your region. You can copy the address and paste it into the app manually, or search for the app in the App Store."
                showOrderAlert = true
            }
        }
    }

    // Google Places Autocomplete API
    func fetchAutocompleteSuggestions(for input: String) {
        let apiKey = "AIzaSyALKwJi3EGOjCLZzY13ZUnneMtBMxbAbQ4"
        let inputEncoded = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://maps.googleapis.com/maps/api/place/autocomplete/json?input=\(inputEncoded)&key=\(apiKey)"
        guard let url = URL(string: urlString) else { return }
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let predictions = json["predictions"] as? [[String: Any]] else {
                DispatchQueue.main.async { autocompleteSuggestions = [] }
                return
            }
            let suggestions = predictions.compactMap { pred -> AutocompleteSuggestion? in
                guard let desc = pred["description"] as? String, let placeID = pred["place_id"] as? String else { return nil }
                return AutocompleteSuggestion(description: desc, placeID: placeID)
            }
            DispatchQueue.main.async { autocompleteSuggestions = suggestions }
        }
        task.resume()
    }

    // Google Places Details API to get coordinates from place ID
    func fetchPlaceDetails(placeID: String, completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        let apiKey = "AIzaSyALKwJi3EGOjCLZzY13ZUnneMtBMxbAbQ4"
        let urlString = "https://maps.googleapis.com/maps/api/place/details/json?place_id=\(placeID)&key=\(apiKey)"
        guard let url = URL(string: urlString) else { completion(nil); return }
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let geometry = result["geometry"] as? [String: Any],
                  let location = geometry["location"] as? [String: Any],
                  let lat = location["lat"] as? CLLocationDegrees,
                  let lng = location["lng"] as? CLLocationDegrees else {
                completion(nil)
                return
            }
            completion(CLLocationCoordinate2D(latitude: lat, longitude: lng))
        }
        task.resume()
    }

    // Helper to set default range if both locations are set, user hasn't changed it, and locations are new
    func setDefaultRangeIfNeeded() {
        guard !userChangedRange, let origin = userLocation, let dest = destinationCoordinate else { return }
        // Only set defaults if origin or dest has changed
        if let lastOrigin = lastDefaultOrigin, let lastDest = lastDefaultDestination, lastOrigin.latitude == origin.latitude, lastOrigin.longitude == origin.longitude, lastDest.latitude == dest.latitude, lastDest.longitude == dest.longitude {
            return
        }
        lastDefaultOrigin = origin
        lastDefaultDestination = dest
        fetchRoutePolyline(origin: origin, destination: dest) { polyline in
            guard let polyline = polyline else { return }
            let coords = decodePolyline(polyline)
            let totalDistance = coords.enumerated().dropFirst().reduce(0.0) { sum, element in
                sum + haversineDistance(coords[element.offset - 1], element.element)
            }
            let apiKey = "AIzaSyALKwJi3EGOjCLZzY13ZUnneMtBMxbAbQ4"
            let originStr = "\(origin.latitude),\(origin.longitude)"
            let destStr = "\(dest.latitude),\(dest.longitude)"
            let timeUrlStr = "https://maps.googleapis.com/maps/api/directions/json?origin=\(originStr)&destination=\(destStr)&key=\(apiKey)"
            guard let timeUrl = URL(string: timeUrlStr) else { return }
            let timeTask = URLSession.shared.dataTask(with: timeUrl) { data, response, error in
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let routes = json["routes"] as? [[String: Any]],
                      let firstRoute = routes.first,
                      let legs = firstRoute["legs"] as? [[String: Any]],
                      let totalDuration = legs.reduce(0, { acc, leg in
                          acc + ((leg["duration"] as? [String: Any])?["value"] as? Int ?? 0)
                      }) as Int? else {
                    print("Failed to get total route time for default range")
                    return
                }
                let totalTimeMinutes = Double(totalDuration) / 60.0
                let totalDistanceMiles = totalDistance * 0.621371
                var startValue: Double
                var endValue: Double
                if rangeMode == .distance {
                    startValue = totalDistanceMiles / 3.0
                    endValue = (totalDistanceMiles * 2.0) / 3.0
                    startValue = max(0, min(startValue, totalDistanceMiles))
                    endValue = max(startValue, min(endValue, totalDistanceMiles))
                    DispatchQueue.main.async {
                        searchStartMiles = startValue
                        searchEndMiles = endValue
                    }
                } else {
                    startValue = totalTimeMinutes / 3.0
                    endValue = max((totalTimeMinutes * 2.0) / 3.0, startValue + 30.0)
                    startValue = max(0, min(startValue, totalTimeMinutes))
                    endValue = max(startValue, min(endValue, totalTimeMinutes))
                    DispatchQueue.main.async {
                        searchStartMinutes = startValue
                        searchEndMinutes = endValue
                    }
                }
            }
            timeTask.resume()
        }
    }
}

enum SortMode: String, CaseIterable, Identifiable {
    case distance = "Distance"
    case addedTime = "Added Time"
    var id: String { self.rawValue }
}

enum RangeMode: String, CaseIterable, Identifiable {
    case distance = "Distance (mi)"
    case time = "Time (min)"
    var id: String { self.rawValue }
}

struct DestinationTabView: View {
    @Binding var searchMode: SearchMode
    @Binding var pastedLink: String
    @Binding var manualDestination: String
    @Binding var autocompleteSuggestions: [AutocompleteSuggestion]
    @Binding var destinationCoordinate: CLLocationCoordinate2D?
    @Binding var userLocation: CLLocationCoordinate2D?
    let locationManager: LocationManager
    let geocodeAddress: (String, @escaping (CLLocationCoordinate2D?) -> Void) -> Void
    let resolveShortURL: (String, @escaping (URL?) -> Void) -> Void
    let fetchAutocompleteSuggestions: (String) -> Void
    let fetchPlaceDetails: (String, @escaping (CLLocationCoordinate2D?) -> Void) -> Void
    @Binding var selectedTab: Int
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Picker("Destination Input Mode", selection: $searchMode) {
                    ForEach(SearchMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                
                if searchMode == .link {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Paste your Google Maps link below:")
                            .font(.headline)
                        TextField("Paste link here", text: $pastedLink)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .padding(.horizontal)
                        Button(action: {
                            print("Pasted Google Maps link: \(pastedLink)")
                            resolveShortURL(pastedLink) { resolvedURL in
                                if let resolvedURL = resolvedURL {
                                    print("Resolved URL: \(resolvedURL)")
                                    if let components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false),
                                       let queryItems = components.queryItems {
                                        if let daddr = queryItems.first(where: { $0.name == "daddr" })?.value {
                                            print("Destination address: \(daddr)")
                                            let decodedAddress = daddr.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? daddr
                                            print("Decoded address for geocoding: \(decodedAddress)")
                                            geocodeAddress(decodedAddress) { coordinate in
                                                if let coordinate = coordinate {
                                                    print("Destination coordinate: \(coordinate.latitude), \(coordinate.longitude)")
                                                    destinationCoordinate = coordinate
                                                    selectedTab = 1 // Set selected tab to 1 when destination is set from link
                                                } else {
                                                    print("Failed to geocode destination address")
                                                }
                                            }
                                        } else if let q = queryItems.first(where: { $0.name == "q" })?.value {
                                            print("Destination address from 'q': \(q)")
                                            let decodedAddress = q.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? q
                                            print("Decoded address for geocoding: \(decodedAddress)")
                                            geocodeAddress(decodedAddress) { coordinate in
                                                if let coordinate = coordinate {
                                                    print("Destination coordinate: \(coordinate.latitude), \(coordinate.longitude)")
                                                    destinationCoordinate = coordinate
                                                    selectedTab = 1 // Set selected tab to 1 when destination is set from link
                                                } else {
                                                    print("Failed to geocode destination address from 'q'")
                                                }
                                            }
                                        } else if let path = components.path.removingPercentEncoding {
                                            // Try to extract address from /maps/place/ or /maps/search/
                                            if path.contains("/maps/place/") {
                                                let address = path.replacingOccurrences(of: "/maps/place/", with: "")
                                                print("Extracted address from place path: \(address)")
                                                geocodeAddress(address) { coordinate in
                                                    if let coordinate = coordinate {
                                                        print("Destination coordinate: \(coordinate.latitude), \(coordinate.longitude)")
                                                        destinationCoordinate = coordinate
                                                        selectedTab = 1 // Set selected tab to 1 when destination is set from link
                                                    } else {
                                                        print("Failed to geocode extracted address")
                                                    }
                                                }
                                            } else if path.contains("/maps/search/") {
                                                let address = path.replacingOccurrences(of: "/maps/search/", with: "")
                                                print("Extracted address from search path: \(address)")
                                                geocodeAddress(address) { coordinate in
                                                    if let coordinate = coordinate {
                                                        print("Destination coordinate: \(coordinate.latitude), \(coordinate.longitude)")
                                                        destinationCoordinate = coordinate
                                                        selectedTab = 1 // Set selected tab to 1 when destination is set from link
                                                    } else {
                                                        print("Failed to geocode extracted address")
                                                    }
                                                }
                                            } else {
                                                print("No recognizable destination in URL path. Please enter the address manually.")
                                            }
                                        } else {
                                            print("No destination address (daddr) found in URL and no recognizable path. Please enter the address manually.")
                                        }
                                    } else {
                                        print("Failed to parse URL components")
                                    }
                                } else {
                                    print("Failed to resolve URL")
                                }
                            }
                            if let userLoc = locationManager.location {
                                print("User location: \(userLoc.latitude), \(userLoc.longitude)")
                                userLocation = userLoc
                            } else {
                                print("User location not available yet")
                            }
                        }) {
                            Text("Process Link")
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Search for a destination by name or address:")
                            .font(.headline)
                        TextField("Enter address or business name", text: $manualDestination, onEditingChanged: { _ in }, onCommit: {})
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .padding(.horizontal)
                            .onChange(of: manualDestination) { _, newValue in
                                let input = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !input.isEmpty {
                                    fetchAutocompleteSuggestions(input)
                                } else {
                                    autocompleteSuggestions = []
                                }
                            }
                        
                        if !autocompleteSuggestions.isEmpty {
                            List(autocompleteSuggestions) { suggestion in
                                Button(action: {
                                    manualDestination = suggestion.description
                                    autocompleteSuggestions = []
                                    fetchPlaceDetails(suggestion.placeID) { coordinate in
                                        if let coordinate = coordinate {
                                            print("Destination coordinate: \(coordinate.latitude), \(coordinate.longitude)")
                                            destinationCoordinate = coordinate
                                            selectedTab = 1 // Set selected tab to 1 when destination is set from autocomplete
                                        } else {
                                            print("Failed to get coordinates from place ID")
                                        }
                                    }
                                    if let userLoc = locationManager.location {
                                        print("User location: \(userLoc.latitude), \(userLoc.longitude)")
                                        userLocation = userLoc
                                    } else {
                                        print("User location not available yet")
                                    }
                                }) {
                                    Text(suggestion.description)
                                }
                            }
                            .frame(height: 200)
                        } else {
                            Button(action: {
                                let input = manualDestination.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !input.isEmpty else { return }
                                print("Manual destination search: \(input)")
                                geocodeAddress(input) { coordinate in
                                    if let coordinate = coordinate {
                                        print("Destination coordinate: \(coordinate.latitude), \(coordinate.longitude)")
                                        destinationCoordinate = coordinate
                                        selectedTab = 1 // Set selected tab to 1 when destination is set from manual search
                                    } else {
                                        print("Failed to geocode manual destination")
                                    }
                                }
                                if let userLoc = locationManager.location {
                                    print("User location: \(userLoc.latitude), \(userLoc.longitude)")
                                    userLocation = userLoc
                                } else {
                                    print("User location not available yet")
                                }
                            }) {
                                Text("Search Destination")
                                    .padding()
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                        }
                    }
                }
                
                if let dest = destinationCoordinate {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Destination Set:")
                            .font(.headline)
                        Text("Latitude: \(dest.latitude)")
                        Text("Longitude: \(dest.longitude)")
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }
                
                if let userLoc = userLocation {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Location:")
                            .font(.headline)
                        Text("Latitude: \(userLoc.latitude)")
                        Text("Longitude: \(userLoc.longitude)")
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            .padding()
        }
    }
}

struct SearchSettingsTabView: View {
    @Binding var selectedPlaceType: String
    @Binding var filterText: String
    @Binding var rangeMode: RangeMode
    @Binding var searchStartMiles: Double
    @Binding var searchEndMiles: Double
    @Binding var searchStartMinutes: Double
    @Binding var searchEndMinutes: Double
    @Binding var searchEntireRoute: Bool
    @Binding var userChangedRange: Bool
    let userLocation: CLLocationCoordinate2D?
    let destinationCoordinate: CLLocationCoordinate2D?
    @Binding var placeResults: [(PlaceResult, Int)]
    @Binding var routePolyline: String?
    let fetchRoutePolyline: (CLLocationCoordinate2D, CLLocationCoordinate2D, @escaping (String?) -> Void) -> Void
    let decodePolyline: (String) -> [CLLocationCoordinate2D]
    let haversineDistance: (CLLocationCoordinate2D, CLLocationCoordinate2D) -> Double
    let searchPlaces: (CLLocationCoordinate2D, String, @escaping ([PlaceResult]) -> Void) -> Void
    @Binding var selectedTab: Int
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Show Google Map with route
                GoogleMapView(
                    userLocation: userLocation,
                    destination: destinationCoordinate,
                    polyline: routePolyline,
                    places: []
                )
                .frame(height: 300)
                
                VStack(alignment: .leading, spacing: 16) {
                    Text("Search Settings")
                        .font(.title2)
                        .bold()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Place Type:")
                            .font(.headline)
                        Picker("Place Type", selection: $selectedPlaceType) {
                            Text("Any").tag("any")
                            Text("Gas Stations").tag("gas_station")
                            Text("Restaurants").tag("restaurant")
                            Text("Fast Food").tag("meal_takeaway")
                            Text("Coffee Shops").tag("cafe")
                            Text("Hotels").tag("lodging")
                        }
                        .pickerStyle(MenuPickerStyle())
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Filter (for 'Any' category or additional filtering):")
                            .font(.headline)
                        TextField("Filter results (e.g. Exxon, Walmart)", text: $filterText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Search entire route", isOn: $searchEntireRoute)
                            .padding(.bottom, 4)
                        
                        if !searchEntireRoute {
                            Picker("Range Mode", selection: $rangeMode) {
                                ForEach(RangeMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            
                            if rangeMode == .distance {
                                HStack {
                                    Text("Start (mi):")
                                    TextField("Start", value: $searchStartMiles, formatter: NumberFormatter(), onEditingChanged: { editing in if editing { userChangedRange = true } })
                                        .keyboardType(.numberPad)
                                        .frame(width: 60)
                                    Text("End (mi):")
                                    TextField("End", value: $searchEndMiles, formatter: NumberFormatter(), onEditingChanged: { editing in if editing { userChangedRange = true } })
                                        .keyboardType(.numberPad)
                                        .frame(width: 60)
                                }
                            } else {
                                HStack {
                                    Text("Start (min):")
                                    TextField("Start", value: $searchStartMinutes, formatter: NumberFormatter(), onEditingChanged: { editing in if editing { userChangedRange = true } })
                                        .keyboardType(.numberPad)
                                        .frame(width: 60)
                                    Text("End (min):")
                                    TextField("End", value: $searchEndMinutes, formatter: NumberFormatter(), onEditingChanged: { editing in if editing { userChangedRange = true } })
                                        .keyboardType(.numberPad)
                                        .frame(width: 60)
                                }
                            }
                        }
                    }
                    
                    Button(action: {
                        guard let origin = userLocation, let dest = destinationCoordinate else {
                            print("User location or destination not set")
                            return
                        }
                        
                        fetchRoutePolyline(origin, dest) { polyline in
                            if let polyline = polyline {
                                print("Route polyline: \(polyline)")
                                routePolyline = polyline
                                
                                // Calculate total route distance and time
                                let coords = decodePolyline(polyline)
                                let totalDistance = coords.enumerated().dropFirst().reduce(0.0) { sum, element in
                                    sum + haversineDistance(coords[element.offset - 1], element.element)
                                }
                                
                                // Get total route time from Directions API
                                let apiKey = "AIzaSyALKwJi3EGOjCLZzY13ZUnneMtBMxbAbQ4"
                                let originStr = "\(origin.latitude),\(origin.longitude)"
                                let destStr = "\(dest.latitude),\(dest.longitude)"
                                let timeUrlStr = "https://maps.googleapis.com/maps/api/directions/json?origin=\(originStr)&destination=\(destStr)&key=\(apiKey)"
                                
                                guard let timeUrl = URL(string: timeUrlStr) else { return }
                                let timeTask = URLSession.shared.dataTask(with: timeUrl) { data, response, error in
                                    guard let data = data,
                                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                          let routes = json["routes"] as? [[String: Any]],
                                          let firstRoute = routes.first,
                                          let legs = firstRoute["legs"] as? [[String: Any]],
                                          let totalDuration = legs.reduce(0, { acc, leg in
                                              acc + ((leg["duration"] as? [String: Any])?["value"] as? Int ?? 0)
                                          }) as Int? else {
                                        print("Failed to get total route time")
                                        return
                                    }
                                    
                                    let totalTimeMinutes = Double(totalDuration) / 60.0
                                    let totalDistanceMiles = totalDistance * 0.621371
                                    
                                    // Continue with existing search logic using the calculated values
                                    let startKm = searchStartMiles * 1.60934
                                    let endKm = searchEndMiles * 1.60934
                                    
                                    // Sample points between startKm and endKm and search for places
                                    var sampledCoords: [CLLocationCoordinate2D] = []
                                    if searchEntireRoute {
                                        sampledCoords = coords
                                    } else {
                                        var cumulativeDistance = 0.0
                                        for i in 1..<coords.count {
                                            let segment = haversineDistance(coords[i-1], coords[i])
                                            cumulativeDistance += segment
                                            if rangeMode == .distance {
                                                if cumulativeDistance >= startKm && cumulativeDistance <= endKm {
                                                    sampledCoords.append(coords[i])
                                                }
                                            } else {
                                                // For time-based, keep as before (could be improved with time estimation)
                                                if cumulativeDistance >= startKm && cumulativeDistance <= endKm {
                                                    sampledCoords.append(coords[i])
                                                }
                                            }
                                        }
                                    }
                                    
                                    print("Sampled coordinates in range (", startKm, "km to", endKm, "km):")
                                    for coord in sampledCoords {
                                        print("\(coord.latitude), \(coord.longitude)")
                                    }
                                    
                                    // Search for places near sampled points
                                    var allPlaces: [PlaceResult] = []
                                    let group = DispatchGroup()
                                    for coord in sampledCoords {
                                        group.enter()
                                        searchPlaces(coord, selectedPlaceType) { places in
                                            allPlaces.append(contentsOf: places)
                                            group.leave()
                                        }
                                    }
                                    
                                    group.notify(queue: .main) {
                                        // Remove duplicates by name and location
                                        var uniqueDict: [String: PlaceResult] = [:]
                                        for place in allPlaces {
                                            let key = "\(place.name)-\(place.location.latitude)-\(place.location.longitude)"
                                            uniqueDict[key] = place
                                        }
                                        let uniquePlaces = Array(uniqueDict.values)
                                        let sortedPlaces = uniquePlaces.sorted { $0.distanceFromUser < $1.distanceFromUser }
                                        print("\nSorted places by distance from user:")
                                        for place in sortedPlaces {
                                            print("\(place.name): \(place.location.latitude), \(place.location.longitude) - \(String(format: "%.2f", place.distanceFromUser)) km away")
                                        }
                                        
                                        // --- Added time to route logic ---
                                        guard let _ = userLocation, let _ = destinationCoordinate else { return }
                                        // First, get the original route time
                                        let originalUrlStr = "https://maps.googleapis.com/maps/api/directions/json?origin=\(originStr)&destination=\(destStr)&key=\(apiKey)"
                                        guard let originalUrl = URL(string: originalUrlStr) else { return }
                                        let originalTask = URLSession.shared.dataTask(with: originalUrl) { data, response, error in
                                            guard let data = data,
                                                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                                  let routes = json["routes"] as? [[String: Any]],
                                                  let firstRoute = routes.first,
                                                  let legs = firstRoute["legs"] as? [[String: Any]],
                                                  let totalDuration = legs.reduce(0, { acc, leg in
                                                      acc + ((leg["duration"] as? [String: Any])?["value"] as? Int ?? 0)
                                                  }) as Int? else {
                                                print("Failed to get original route time")
                                                return
                                            }
                                            // For each place, get the detour time
                                            var placeTimes: [(PlaceResult, Int)] = []
                                            let detourGroup = DispatchGroup()
                                            for place in uniquePlaces {
                                                detourGroup.enter()
                                                let waypointStr = "\(place.location.latitude),\(place.location.longitude)"
                                                let detourUrlStr = "https://maps.googleapis.com/maps/api/directions/json?origin=\(originStr)&waypoints=via:\(waypointStr)&destination=\(destStr)&key=\(apiKey)"
                                                guard let detourUrl = URL(string: detourUrlStr) else {
                                                    detourGroup.leave()
                                                    continue
                                                }
                                                let detourTask = URLSession.shared.dataTask(with: detourUrl) { data, response, error in
                                                    var addedTime = Int.max
                                                    if let data = data,
                                                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                                       let routes = json["routes"] as? [[String: Any]],
                                                       let firstRoute = routes.first,
                                                       let legs = firstRoute["legs"] as? [[String: Any]],
                                                       let totalDetourDuration = legs.reduce(0, { acc, leg in
                                                           acc + ((leg["duration"] as? [String: Any])?["value"] as? Int ?? 0)
                                                       }) as Int? {
                                                        addedTime = totalDetourDuration - totalDuration
                                                    }
                                                    placeTimes.append((place, addedTime))
                                                    detourGroup.leave()
                                                }
                                                detourTask.resume()
                                            }
                                            detourGroup.notify(queue: .main) {
                                                let sortedByTime = placeTimes.sorted { $0.1 < $1.1 }
                                                print("\nSorted places by added time to route:")
                                                for (place, addedTime) in sortedByTime {
                                                    let minutes = addedTime == Int.max ? "N/A" : String(addedTime / 60)
                                                    print("\(place.name): \(place.location.latitude), \(place.location.longitude) - +\(minutes) min")
                                                }
                                                // Store results for UI
                                                placeResults = placeTimes
                                                selectedTab = 2
                                            }
                                        }
                                        originalTask.resume()
                                    }
                                }
                                timeTask.resume()
                            } else {
                                print("Failed to fetch route polyline")
                            }
                        }
                    }) {
                        Text("Search Along Route")
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .disabled(userLocation == nil || destinationCoordinate == nil)
                }
            }
            .padding()
        }
    }
}

struct ResultsTabView: View {
    let placeResults: [(PlaceResult, Int)]
    @Binding var sortMode: SortMode
    let filterText: String
    @Binding var selectedStop: PlaceResult?
    @Binding var showOrderAlert: Bool
    @Binding var addressToCopy: String
    @Binding var alertMessage: String
    let openInGoogleMaps: (PlaceResult) -> Void
    let orderURLForPlace: (PlaceResult) -> URL?
    let tryOpenOrderURL: (URL, PlaceResult) -> Void
    let userLocation: CLLocationCoordinate2D?
    let destinationCoordinate: CLLocationCoordinate2D?
    let routePolyline: String?
    
    // Computed property for sorted results
    var sortedPlaceResults: [(PlaceResult, Int)] {
        switch sortMode {
        case .distance:
            return placeResults.sorted { $0.0.distanceFromUser < $1.0.distanceFromUser }
        case .addedTime:
            return placeResults.sorted { 
                if $0.1 == $1.1 {
                    // If added times are equal, sort by distance (closer first)
                    return $0.0.distanceFromUser < $1.0.distanceFromUser
                }
                return $0.1 < $1.1 
            }
        }
    }

    // Computed property for filtered and sorted results
    var filteredPlaceResults: [(PlaceResult, Int)] {
        let lowercasedFilter = filterText.lowercased()
        return sortedPlaceResults.filter { place, _ in
            filterText.isEmpty || place.name.lowercased().contains(lowercasedFilter)
        }
    }
    
    var body: some View {
        VStack {
            if placeResults.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                    Text("No Results Yet")
                        .font(.title2)
                        .bold()
                    Text("Set your destination and search settings, then tap 'Search Along Route' to find places.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 16) {
                    // Show Google Map with route and places
                    GoogleMapView(
                        userLocation: userLocation,
                        destination: destinationCoordinate,
                        polyline: routePolyline,
                        places: filteredPlaceResults.map { $0.0.location }
                    )
                    .frame(height: 300)
                    
                    VStack(spacing: 12) {
                        HStack {
                            Text("Results (\(filteredPlaceResults.count))")
                                .font(.headline)
                            Spacer()
                            Picker("Sort by", selection: $sortMode) {
                                ForEach(SortMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                        }
                        
                        List {
                            ForEach(filteredPlaceResults, id: \.0.id) { (place, addedTime) in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(place.name).font(.headline)
                                    Text(String(format: "%.2f km away", place.distanceFromUser))
                                    Text(addedTime == Int.max ? "Added time: N/A" : "Added time: \(addedTime / 60) min")
                                    HStack(spacing: 12) {
                                        Button("Select") {
                                            selectedStop = place
                                            openInGoogleMaps(place)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        if let orderURL = orderURLForPlace(place) {
                                            Button("Order") {
                                                tryOpenOrderURL(orderURL, place)
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .padding()
    }
}

struct HelpView: View {
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("How to Use RouteStopFinder")
                        .font(.title2)
                        .bold()
                        .padding(.bottom, 8)
                    Group {
                        Text("1. Enter Your Destination")
                            .font(.headline)
                        Text("Paste a Google Maps link or search for a destination by name or address. Use autocomplete for quick selection.")
                        Text("2. Set Your Preferences")
                            .font(.headline)
                        Text("Choose the type of place to search for (e.g., gas stations, restaurants). Select 'Any' for open search using the filter text. Optionally, set a distance or time range, or enable 'Search entire route' to search the whole way.")
                        Text("3. View Results")
                            .font(.headline)
                        Text("Results are shown on the map and in a list. Filter by name (e.g., 'Exxon'). Sort by distance or added time.")
                        Text("4. Select a Stop")
                            .font(.headline)
                        Text("Tap 'Select' to add a stop as a waypoint in Google Maps. Tap 'Order' for supported chains to open their app or website, and the address will be copied for easy pasting.")
                        Text("5. Tips & Fallbacks")
                            .font(.headline)
                        Text("If an ordering app can't be opened, you'll see an alert and can copy the address manually. Not all chains support deep links.")
                    }
                    Divider()
                    Text("Need more help? Contact support or check the app website for FAQs and updates.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
            .navigationTitle("Help & Instructions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        UIApplication.shared.connectedScenes
                            .compactMap { $0 as? UIWindowScene }
                            .flatMap { $0.windows }
                            .first { $0.isKeyWindow }?.rootViewController?.dismiss(animated: true)
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView().environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}

extension View {
    func hideKeyboardOnTap() -> some View {
        self.gesture(
            TapGesture().onEnded { _ in
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        )
    }
}
