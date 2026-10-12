import SwiftUI

/// The renter's preference flow, one step per screen, saved at the end.
@MainActor
struct PreferencesFlowView: View {
    @State private var model: PreferencesEditorModel
    @Environment(\.dismiss) private var dismiss
    private let onSaved: (RenterProfile) -> Void

    init(model: PreferencesEditorModel, onSaved: @escaping (RenterProfile) -> Void) {
        _model = State(initialValue: model)
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progress
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        stepContent
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(maxHeight: .infinity)
                footer
            }
            .background(Brand.cream)
            .navigationTitle(model.isEditing ? "Your search" : "Set up your search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .tint(Brand.magenta)
                }
                if model.isEditing && model.step != .area {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .tint(Brand.magenta)
                            .disabled(model.isSaving)
                    }
                }
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(
                value: Double(model.step.rawValue + 1),
                total: Double(PreferencesEditorModel.Step.allCases.count)
            )
            .tint(Brand.magenta)
            Text("Step \(model.step.rawValue + 1) of \(PreferencesEditorModel.Step.allCases.count) · \(model.step.title)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.ink)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .dates: DatesStep(model: model)
        case .budget: BudgetStep(model: model)
        case .spaceType: SpaceTypeStep(model: model)
        case .preferences: ImportanceStep(model: model)
        case .area: PinPickerView(model: model)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let message = model.errorMessage, !message.isEmpty {
                ErrorText(message)
            }
            HStack(spacing: 12) {
                if model.step != .dates {
                    Button("Back") { model.back() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if model.step == .area {
                    Button(model.isSaving ? "Saving…" : "Save") { save() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.isSaving)
                        .accessibilityIdentifier("save-search-button")
                } else {
                    Button("Next") { model.next() }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("search-next-button")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Brand.cream)
    }

    private func save() {
        Task {
            if let saved = await model.save() {
                onSaved(saved)
                dismiss()
            }
        }
    }
}

@MainActor
private struct DatesStep: View {
    @Bindable var model: PreferencesEditorModel

    var body: some View {
        Text("When do you need a place?")
            .font(.headline)
            .foregroundStyle(Brand.ink)
        FormField("Move in", error: model.fieldErrors["start_date"]) {
            DatePicker("Move in", selection: $model.startDate, displayedComponents: .date)
                .labelsHidden()
        }
        FormField("Move out", error: model.fieldErrors["end_date"]) {
            DatePicker("Move out", selection: $model.endDate, displayedComponents: .date)
                .labelsHidden()
        }
        FormField("How flexible are these dates?", hint: "Places that start or end a little differently still show up.") {
            Picker("Flexibility", selection: $model.flexibilityDays) {
                ForEach(PreferencesEditorModel.flexibilityChoices, id: \.self) { days in
                    Text(days == 0 ? "Exact" : "± \(days)d").tag(days)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

@MainActor
private struct BudgetStep: View {
    @Bindable var model: PreferencesEditorModel

    var body: some View {
        FormField(
            "Most you'd pay each month",
            hint: "Places under your budget rank higher.",
            error: model.fieldErrors["max_rent_cents"]
        ) {
            HStack {
                Text("$").foregroundStyle(Brand.ink)
                TextField("1,100", text: $model.budgetText)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("budget-field")
            }
            .brandField()
        }
    }
}

@MainActor
private struct SpaceTypeStep: View {
    @Bindable var model: PreferencesEditorModel

    var body: some View {
        Text("What kind of place would you take? Choose all that work.")
            .font(.headline)
            .foregroundStyle(Brand.ink)
        ForEach(SpaceType.allCases) { type in
            let isOn = model.spaceTypes.contains(type)
            Button {
                model.toggle(type)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(type.title).font(.headline)
                        Text(type.detail).font(.subheadline).multilineTextAlignment(.leading)
                    }
                }
                .foregroundStyle(Brand.ink)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isOn ? Brand.yellow : Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
        if let error = model.fieldErrors["space_type"] {
            ErrorText(error)
        }
        if !model.spaceTypes.isEmpty && model.spaceTypes.count < SpaceType.allCases.count {
            FormField("How strict?") {
                ImportancePicker(selection: $model.spaceTypeImportance, includeOff: false)
            }
        }
    }
}

@MainActor
private struct ImportanceStep: View {
    @Bindable var model: PreferencesEditorModel

    var body: some View {
        Text("Set each one to must have, nice to have, or off. Must-haves hide places without them.")
            .font(.subheadline)
            .foregroundStyle(Brand.ink)

        ForEach(PreferenceField.flags) { field in
            FormField(field.title, error: model.fieldErrors[field.rawValue]) {
                ImportancePicker(selection: Binding(
                    get: { model.importance(of: field) },
                    set: { model.setImportance($0, of: field) }
                ))
            }
        }

        FormField(PreferenceField.housemateCount.title) {
            VStack(alignment: .leading, spacing: 8) {
                Stepper(value: $model.housemateCount, in: 0...10) {
                    Text(model.housemateCount == 0 ? "No housemates" : "At most \(model.housemateCount)")
                        .foregroundStyle(Brand.ink)
                }
                ImportancePicker(selection: $model.housemateCountImportance)
            }
        }

        FormField(
            "Who you'd live with",
            hint: "Whole places have nobody staying, so they always fit."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Who you'd live with", selection: $model.liveWith) {
                    ForEach(LiveWithChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                if model.liveWith != .noPreference {
                    ImportancePicker(selection: $model.liveWithImportance, includeOff: false)
                }
            }
        }
    }
}

/// Must have, nice to have, off.
struct ImportancePicker: View {
    @Binding var selection: Importance
    var includeOff = true

    var body: some View {
        Picker("Importance", selection: $selection) {
            ForEach(Importance.allCases.filter { includeOff || $0 != .off }) { importance in
                Text(importance.title).tag(importance)
            }
        }
        .pickerStyle(.segmented)
    }
}

#Preview("New") {
    PreferencesFlowView(
        model: PreferencesEditorModel(
            profile: nil,
            schoolName: "University of Washington",
            api: PreviewRenterAPI(),
            campusLocator: PreviewCampusLocator()
        ),
        onSaved: { _ in }
    )
}

#Preview("What matters") {
    PreferencesFlowView(
        model: PreferencesEditorModel(
            profile: PreviewData.renterProfile,
            schoolName: "University of Washington",
            api: PreviewRenterAPI(),
            campusLocator: PreviewCampusLocator(),
            startAt: .preferences
        ),
        onSaved: { _ in }
    )
}
