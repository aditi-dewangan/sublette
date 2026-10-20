import MapKit
import PhotosUI
import SwiftUI

/// Creating or editing a listing: one step per screen, then a preview.
@MainActor
struct ListingEditorView: View {
    @State private var model: ListingEditorModel
    @Environment(\.dismiss) private var dismiss
    private let onSaved: (Listing) -> Void

    init(model: ListingEditorModel, onSaved: @escaping (Listing) -> Void) {
        _model = State(initialValue: model)
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progress
                stepContent
                    .frame(maxHeight: .infinity)
                footer
            }
            .background(Brand.cream)
            .navigationTitle(model.isEditing ? "Edit listing" : "New listing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .tint(Brand.accentText)
                }
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(
                value: Double(model.step.rawValue + 1),
                total: Double(ListingEditorModel.Step.allCases.count)
            )
            .tint(Brand.accentText)
            Text("Step \(model.step.rawValue + 1) of \(ListingEditorModel.Step.allCases.count) · \(model.step.title)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.ink)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .photos:
            PhotosStepView(model: model)
        case .address:
            EditorPage { AddressStepView(model: model) }
        case .rentAndDates:
            EditorPage { RentStepView(model: model) }
        case .space:
            EditorPage { SpaceStepView(model: model) }
        case .household:
            EditorPage { HouseholdStepView(model: model) }
        case .whoCanTakeIt:
            EditorPage { WhoStepView(model: model) }
        case .landlordConsent:
            EditorPage { ConsentStepView(model: model) }
        case .preview:
            EditorPage { PreviewStepView(model: model) }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let message = model.errorMessage {
                ErrorText(message)
            }
            if model.step == .preview {
                if model.isPublished {
                    Button(model.isSaving ? "Saving…" : "Save changes") { finish(publish: true) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.isSaving)
                } else {
                    Button(model.isSaving ? "Publishing…" : "Publish") { finish(publish: true) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.isSaving)
                        .accessibilityIdentifier("publish-listing-button")
                    Button("Save as draft") { finish(publish: false) }
                        .buttonStyle(LinkButtonStyle())
                        .disabled(model.isSaving)
                }
            }
            HStack(spacing: 12) {
                if model.step != .photos {
                    Button("Back") { model.back() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if model.step != .preview {
                    Button("Next") { model.next() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.uploadingPhotos > 0 || model.isLocating)
                        .accessibilityIdentifier("editor-next-button")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Brand.cream)
    }

    private func finish(publish: Bool) {
        Task {
            let saved: Listing?
            if publish {
                saved = await model.publish()
            } else {
                saved = await model.saveDraft()
            }
            if let saved {
                onSaved(saved)
                dismiss()
            }
        }
    }
}

/// The scrolling frame shared by every step except photos, which is a list.
private struct EditorPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// A row of options, one selected, used for choices with a sentence each.
private struct OptionCard: View {
    let title: String
    var detail: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                }
            }
            .foregroundStyle(isSelected ? Brand.textOnYellow : Brand.ink)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Brand.yellow : Brand.card,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Brand.ink.opacity(isSelected ? 0.6 : 0.12), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Steps

@MainActor
private struct PhotosStepView: View {
    @Bindable var model: ListingEditorModel
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        List {
            Section {
                let addTitle = model.photos.isEmpty ? "Add photos" : "Add more photos"
                PhotosPicker(
                    selection: $picked,
                    maxSelectionCount: max(1, ListingEditorModel.maxPhotos - model.photos.count),
                    matching: .images
                ) {
                    Label(addTitle, systemImage: "photo.on.rectangle.angled")
                        .foregroundStyle(Brand.accentText)
                }
                .disabled(!model.canAddPhotos)
                if model.uploadingPhotos > 0 {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Uploading \(model.uploadingPhotos) photo\(model.uploadingPhotos == 1 ? "" : "s")…")
                            .font(.subheadline)
                    }
                }
            } footer: {
                Text("At least \(ListingEditorModel.minPhotos), up to \(ListingEditorModel.maxPhotos). Drag to reorder; the first one is the cover.")
            }

            if !model.photos.isEmpty {
                Section("\(model.photos.count) photo\(model.photos.count == 1 ? "" : "s")") {
                    ForEach(Array(model.photos.enumerated()), id: \.element.id) { index, photo in
                        HStack(spacing: 12) {
                            EditorThumbnail(photo: photo)
                            Text(index == 0 ? "Cover photo" : "Photo \(index + 1)")
                                .font(.subheadline)
                                .foregroundStyle(Brand.ink)
                        }
                    }
                    .onMove { source, destination in
                        model.movePhotos(from: source, to: destination)
                    }
                    .onDelete { offsets in
                        model.removePhotos(at: offsets)
                    }
                }
            }

            if let message = model.fieldErrors["photo_keys"] ?? model.photoMessage {
                Section {
                    ErrorText(message)
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else {
                return
            }
            Task {
                var jpegs: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let jpeg = await Task.detached(priority: .userInitiated, operation: {
                           ImageResizer.jpegData(from: data)
                       }).value {
                        jpegs.append(jpeg)
                    } else {
                        model.photoCouldNotBeRead()
                    }
                }
                picked = []
                await model.addPhotos(jpegs)
            }
        }
    }
}

private struct EditorThumbnail: View {
    let photo: EditorPhoto

    var body: some View {
        Group {
            if let data = photo.localJPEG, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let address = photo.remoteURL, let url = URL(string: address) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Brand.cream
                    }
                }
            } else {
                Brand.cream
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}

@MainActor
private struct AddressStepView: View {
    @Bindable var model: ListingEditorModel

    var body: some View {
        FormField(
            "Address",
            hint: "Include the unit number. Only you see it until you match.",
            error: model.fieldErrors["address"]
        ) {
            TextField("4500 University Way NE, Apt 3, Seattle", text: $model.address, axis: .vertical)
                .textContentType(.fullStreetAddress)
                .lineLimit(1...3)
                .brandField()
                .onChange(of: model.address) { _, _ in
                    model.addressEdited()
                }
        }

        Button(model.isLocating ? "Looking it up…" : "Find it on the map") {
            Task { await model.locateAddress() }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(model.isLocating)

        if let message = model.addressMessage ?? model.fieldErrors["latitude"] {
            ErrorText(message)
        }

        if let candidate = model.candidate {
            pinMap(candidate.coordinate)
            Text(candidate.formatted)
                .font(.subheadline)
                .foregroundStyle(Brand.ink)
            if model.form.latitude == candidate.coordinate.latitude,
               model.form.longitude == candidate.coordinate.longitude {
                Label("Location confirmed", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
            } else {
                Button("Yes, the pin is on my building") { model.confirmCandidate() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        } else if let latitude = model.form.latitude, let longitude = model.form.longitude {
            pinMap(Coordinate(latitude: latitude, longitude: longitude))
            Label("Location confirmed", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink)
        }

        Text("Renters see a point about 150 meters away. The exact address is shared only after you match.")
            .font(.footnote)
            .foregroundStyle(Brand.ink.opacity(0.7))
    }

    private func pinMap(_ coordinate: Coordinate) -> some View {
        let center = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return Map(
            initialPosition: .region(
                MKCoordinateRegion(center: center, latitudinalMeters: 600, longitudinalMeters: 600)
            )
        ) {
            Marker("Your place", coordinate: center)
                .tint(Brand.accentText)
        }
        .id("\(coordinate.latitude),\(coordinate.longitude)")
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityLabel("Map with a pin on the address")
    }
}

@MainActor
private struct RentStepView: View {
    @Bindable var model: ListingEditorModel

    var body: some View {
        FormField("Monthly rent", error: model.fieldErrors["rent_cents"]) {
            HStack {
                Text("$").foregroundStyle(Brand.ink)
                TextField("1,200", text: $model.rentText)
                    .keyboardType(.decimalPad)
            }
            .brandField()
        }
        FormField("Deposit", hint: "Optional. Leave empty for none.", error: model.fieldErrors["deposit_cents"]) {
            HStack {
                Text("$").foregroundStyle(Brand.ink)
                TextField("0", text: $model.depositText)
                    .keyboardType(.decimalPad)
            }
            .brandField()
        }
        Toggle("Utilities included", isOn: $model.utilitiesIncluded)
            .tint(Brand.accentText)
            .foregroundStyle(Brand.ink)
        FormField("Move-in", error: model.fieldErrors["start_date"]) {
            DatePicker("Move-in", selection: $model.startDate, displayedComponents: .date)
                .labelsHidden()
                .tint(Brand.accentText)
        }
        FormField("Move-out", error: model.fieldErrors["end_date"]) {
            DatePicker("Move-out", selection: $model.endDate, in: model.startDate..., displayedComponents: .date)
                .labelsHidden()
                .tint(Brand.accentText)
        }
        Text("\(max(0, model.stayDays / 7)) weeks")
            .font(.footnote)
            .foregroundStyle(Brand.ink.opacity(0.7))
    }
}

@MainActor
private struct SpaceStepView: View {
    @Bindable var model: ListingEditorModel

    var body: some View {
        FormField("Type of space", error: model.fieldErrors["space_type"]) {
            VStack(spacing: 10) {
                ForEach(SpaceType.allCases) { type in
                    OptionCard(title: type.title, detail: type.detail, isSelected: model.spaceType == type) {
                        model.spaceType = type
                    }
                }
            }
        }
        FormField("Bedrooms in the home", error: model.fieldErrors["bedrooms"]) {
            Stepper(value: $model.bedrooms, in: 0...10) {
                Text(model.bedrooms == 0 ? "Studio" : "\(model.bedrooms) bedroom\(model.bedrooms == 1 ? "" : "s")")
                    .foregroundStyle(Brand.ink)
            }
        }
        FormField("Bathroom", error: model.fieldErrors["bathroom"]) {
            HStack(spacing: 10) {
                ForEach(Bathroom.allCases) { bathroom in
                    OptionCard(title: bathroom.title, isSelected: model.bathroom == bathroom) {
                        model.bathroom = bathroom
                    }
                }
            }
        }
        VStack(spacing: 12) {
            Toggle("Furnished", isOn: $model.furnished)
            Toggle("In-unit laundry", isOn: $model.laundry)
            Toggle("Parking", isOn: $model.parking)
        }
        .tint(Brand.accentText)
        .foregroundStyle(Brand.ink)
    }
}

@MainActor
private struct HouseholdStepView: View {
    @Bindable var model: ListingEditorModel

    var body: some View {
        FormField("Housemates who are staying", error: model.fieldErrors["housemates_staying"]) {
            Stepper(value: $model.housematesStaying, in: 0...10) {
                Text(model.housematesStaying == 0 ? "None" : "\(model.housematesStaying)")
                    .foregroundStyle(Brand.ink)
            }
        }
        if model.housematesStaying > 0 {
            FormField(
                "Who they are",
                hint: "Renters can ask to live with women or with men.",
                error: model.fieldErrors["household_gender"]
            ) {
                Picker("Who they are", selection: $model.householdGender) {
                    Text("Choose").tag(HouseholdGender?.none)
                    ForEach(HouseholdGender.allCases) { gender in
                        Text(gender.title).tag(HouseholdGender?.some(gender))
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        FormField(
            "About them",
            hint: "Optional. One line. \(ListingEditorModel.noteLimit - model.housematesNote.count) characters left.",
            error: model.fieldErrors["housemates_note"]
        ) {
            TextField("Two grad students, quiet, both cook.", text: $model.housematesNote, axis: .vertical)
                .lineLimit(2...3)
                .brandField()
        }
        FormField("Pets", error: model.fieldErrors["pets_allowed"]) {
            YesNoPicker(selection: $model.petsAllowed, yesTitle: "Pets welcome", noTitle: "No pets")
        }
        FormField("Smoking", error: model.fieldErrors["smoking_allowed"]) {
            YesNoPicker(selection: $model.smokingAllowed, yesTitle: "Smokers welcome", noTitle: "No smoking")
        }
    }
}

@MainActor
private struct WhoStepView: View {
    @Bindable var model: ListingEditorModel

    var body: some View {
        Toggle(model.schoolOnlyTitle, isOn: $model.sameSchoolOnly)
            .tint(Brand.accentText)
            .foregroundStyle(Brand.ink)

        FormField("Minimum stay", error: model.fieldErrors["min_stay_days"]) {
            Stepper(value: $model.minStayWeeks, in: 0...52) {
                Text(model.minStayWeeks == 0 ? "No minimum" : "At least \(model.minStayWeeks) week\(model.minStayWeeks == 1 ? "" : "s")")
                    .foregroundStyle(Brand.ink)
            }
        }

        if model.spaceType?.isShared == true {
            FormField(
                "Gender preference",
                hint: "Only for a shared home. Non-binary renters can take a place for women or for men.",
                error: model.fieldErrors["gender_preference"]
            ) {
                Picker("Gender preference", selection: $model.genderPreference) {
                    ForEach(GenderPreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
            }
        } else {
            Text("A gender preference isn't offered for a whole place.")
                .font(.footnote)
                .foregroundStyle(Brand.ink.opacity(0.7))
        }
    }
}

@MainActor
private struct ConsentStepView: View {
    @Bindable var model: ListingEditorModel

    var body: some View {
        Text("Has your landlord approved subletting?")
            .font(.headline)
            .foregroundStyle(Brand.ink)
        Text("Many leases need the landlord's permission, and the rules depend on your state. Renters see your answer.")
            .font(.subheadline)
            .foregroundStyle(Brand.ink)
        FormField("Landlord consent", error: model.fieldErrors["landlord_consent"]) {
            YesNoPicker(selection: $model.landlordConsent, yesTitle: "Yes, approved", noTitle: "Not yet")
        }
        if model.landlordConsent == false {
            Label(
                "Subletting without permission can end in eviction for both of you. Check your lease before you agree to anything.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.footnote.weight(.medium))
            .foregroundStyle(Brand.ink)
            .padding(12)
            .background(Brand.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

@MainActor
private struct PreviewStepView: View {
    @Bindable var model: ListingEditorModel

    var body: some View {
        Text("This is what renters see. Your exact address stays hidden until you match.")
            .font(.subheadline)
            .foregroundStyle(Brand.ink)
        ListingCardView(listing: model.previewListing, localImages: localImages)
        let missing = model.problems(on: .preview)
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Still to do before publishing")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                ForEach(missing.values.sorted(), id: \.self) { message in
                    ErrorText(message)
                }
            }
        }
    }

    private var localImages: [String: Data] {
        Dictionary(
            model.photos.compactMap { photo in photo.localJPEG.map { (photo.key, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

#Preview("New listing") {
    ListingEditorView(model: AppContainer.preview().makeListingEditor(for: .new)) { _ in }
}

#Preview("Editing") {
    let model = AppContainer.preview().makeListingEditor(for: .edit(PreviewData.listing))
    model.step = .preview
    return ListingEditorView(model: model) { _ in }
}
