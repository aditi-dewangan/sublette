import MapKit
import SwiftUI

extension Coordinate {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Where the renter wants to live: a pin in the middle of the map, the circle
/// it searches, a radius slider and a shortcut to their campus.
///
/// The pin stays in the middle and the map moves under it, so dragging the
/// map is dragging the pin. A tap moves the pin to the spot tapped.
@MainActor
struct PinPickerView: View {
    @Bindable var model: PreferencesEditorModel
    @State private var position: MapCameraPosition = .automatic
    /// Where the map is looking, before a pin has been placed.
    @State private var visibleCenter: Coordinate?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            map
            if model.center == nil {
                Button("Put the pin here") {
                    if let visibleCenter {
                        model.mapMoved(to: visibleCenter)
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(visibleCenter == nil)
            }
            Button(model.isLocatingCampus ? "Finding \(model.schoolName)…" : "My campus") {
                Task { await model.useMyCampus() }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isLocatingCampus)
            .accessibilityIdentifier("my-campus-button")

            if let message = model.campusMessage ?? model.fieldErrors["pin"] {
                ErrorText(message)
            }

            FormField("How far from the pin", hint: "Listings inside the circle can show up in your deck.") {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: radiusBinding, in: Double(SearchPin.minRadiusM)...Double(SearchPin.maxRadiusM), step: 250)
                        .tint(Brand.accentText)
                        .accessibilityValue(model.radiusText)
                    Text(model.radiusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.ink)
                }
            }

            Text("Only you see your pin. Listers never see where you searched.")
                .font(.footnote)
                .foregroundStyle(Brand.ink.opacity(0.7))
        }
        .onAppear {
            if let center = model.center {
                position = Self.region(center, radiusM: model.radiusM)
            } else {
                Task { await model.useMyCampus() }
            }
        }
        .onChange(of: model.recenterCount) { _, _ in
            if let center = model.center {
                withAnimation { position = Self.region(center, radiusM: model.radiusM) }
            }
        }
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $position) {
                if let center = model.center {
                    MapCircle(center: center.clCoordinate, radius: CLLocationDistance(model.radiusM))
                        .foregroundStyle(Brand.yellow.opacity(0.28))
                        .stroke(Brand.ink.opacity(0.55), lineWidth: 1.5)
                }
            }
            .mapControls { MapCompass() }
            .onMapCameraChange(frequency: .onEnd) { context in
                let moved = Coordinate(context.region.center)
                visibleCenter = moved
                if model.center != nil {
                    model.mapMoved(to: moved)
                }
            }
            .onTapGesture { point in
                guard let tapped = proxy.convert(point, from: .local) else {
                    return
                }
                model.mapMoved(to: Coordinate(tapped))
                withAnimation { position = Self.region(Coordinate(tapped), radiusM: model.radiusM) }
            }
            .overlay {
                Image(systemName: "mappin")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Brand.accentText)
                    .offset(y: -17)
                    .opacity(model.center == nil ? 0.45 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel("Map. Drag it to move your pin.")
    }

    private var radiusBinding: Binding<Double> {
        Binding(
            get: { Double(model.radiusM) },
            set: { model.radiusM = Int($0) }
        )
    }

    static func region(_ center: Coordinate, radiusM: Int) -> MapCameraPosition {
        let span = CLLocationDistance(radiusM) * 2.6
        return .region(MKCoordinateRegion(center: center.clCoordinate, latitudinalMeters: span, longitudinalMeters: span))
    }
}

#Preview {
    ScrollView {
        PinPickerView(model: PreferencesEditorModel(
            profile: PreviewData.renterProfile,
            schoolName: "University of Washington",
            api: PreviewRenterAPI(),
            campusLocator: PreviewCampusLocator(),
            startAt: .area
        ))
        .padding(20)
    }
    .background(Brand.cream)
}
