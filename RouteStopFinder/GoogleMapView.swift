import SwiftUI
import GoogleMaps
import CoreLocation

struct GoogleMapView: UIViewRepresentable {
    let userLocation: CLLocationCoordinate2D?
    let destination: CLLocationCoordinate2D?
    let polyline: String?
    let places: [CLLocationCoordinate2D]

    func makeUIView(context: Context) -> GMSMapView {
        let camera = GMSCameraPosition.camera(withLatitude: userLocation?.latitude ?? 0, longitude: userLocation?.longitude ?? 0, zoom: 8)
        let mapView = GMSMapView(frame: .zero)
        mapView.camera = camera
        mapView.isMyLocationEnabled = true
        return mapView
    }

    func updateUIView(_ mapView: GMSMapView, context: Context) {
        mapView.clear()
        // User location marker
        if let userLoc = userLocation {
            let marker = GMSMarker(position: userLoc)
            marker.title = "You"
            marker.icon = GMSMarker.markerImage(with: .blue)
            marker.map = mapView
        }
        // Destination marker
        if let dest = destination {
            let marker = GMSMarker(position: dest)
            marker.title = "Destination"
            marker.icon = GMSMarker.markerImage(with: .red)
            marker.map = mapView
        }
        // Route polyline
        if let polylineStr = polyline {
            let path = GMSMutablePath()
            let coords = decodePolyline(polylineStr)
            for coord in coords {
                path.add(coord)
            }
            let routePolyline = GMSPolyline(path: path)
            routePolyline.strokeColor = .systemBlue
            routePolyline.strokeWidth = 4
            routePolyline.map = mapView
        }
        // Place markers
        for placeCoord in places {
            let marker = GMSMarker(position: placeCoord)
            marker.title = "Stop"
            marker.icon = GMSMarker.markerImage(with: .green)
            marker.map = mapView
        }
        // --- Fit bounds to all relevant points ---
        var bounds: GMSCoordinateBounds?
        let allCoords: [CLLocationCoordinate2D] = [userLocation, destination].compactMap { $0 } + places
        for coord in allCoords {
            if bounds == nil {
                bounds = GMSCoordinateBounds(coordinate: coord, coordinate: coord)
            } else {
                bounds = bounds!.includingCoordinate(coord)
            }
        }
        if let bounds = bounds {
            let update = GMSCameraUpdate.fit(bounds, withPadding: 60)
            mapView.animate(with: update)
        }
    }

    // Polyline decoder (same as in ContentView)
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
} 