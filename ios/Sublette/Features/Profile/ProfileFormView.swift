import PhotosUI
import SwiftUI

/// The profile questions. Used right after sign-up and again when editing.
@MainActor
struct ProfileFormView: View {
    @Bindable var model: ProfileFormModel
    let saveTitle: String
    /// Called after the profile was saved.
    var onSaved: () -> Void = {}

    @State private var pickedPhoto: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            photoSection

            FormField("First name", error: model.fieldErrors["first_name"]) {
                TextField("First name", text: $model.firstName)
                    .textContentType(.givenName)
                    .brandField()
                    .accessibilityIdentifier("first-name-field")
            }

            FormField("Year", error: model.fieldErrors["year"]) {
                Picker("Year", selection: $model.year) {
                    Text("Choose").tag(Year?.none)
                    ForEach(Year.allCases) { year in
                        Text(year.title).tag(Year?.some(year))
                    }
                }
                .pickerStyle(.menu)
                .tint(Brand.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            FormField("Program or major", error: model.fieldErrors["program"]) {
                TextField("Informatics", text: $model.program)
                    .brandField()
                    .accessibilityIdentifier("program-field")
            }

            FormField(
                "Bio",
                hint: "Optional. Two lines about you. \(model.bioCharactersLeft) characters left.",
                error: bioError
            ) {
                TextField("Tidy, quiet, back in June.", text: $model.bio, axis: .vertical)
                    .lineLimit(2...4)
                    .brandField()
            }

            FormField("Do you smoke?", hint: "Listers can choose non-smokers only.") {
                YesNoPicker(selection: $model.smokes)
            }

            FormField("Do you have pets?", hint: "Listers can choose no pets.") {
                YesNoPicker(selection: $model.hasPets)
            }

            FormField(
                "Gender",
                hint: "Optional. Only used when a shared home has a gender preference."
            ) {
                Picker("Gender", selection: $model.gender) {
                    Text("Prefer not to say").tag(Gender?.none)
                    ForEach(Gender.allCases) { gender in
                        Text(gender.title).tag(Gender?.some(gender))
                    }
                }
                .pickerStyle(.menu)
                .tint(Brand.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if let message = model.errorMessage {
                ErrorText(message)
            }

            Button(model.isSaving ? "Saving…" : saveTitle) {
                Task {
                    if await model.save() {
                        onSaved()
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!model.canSave)
            .accessibilityIdentifier("save-profile-button")
        }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else {
                return
            }
            Task {
                // Decoding and shrinking a full-size photo is slow; keep it off the main thread.
                if let data = try? await item.loadTransferable(type: Data.self),
                   let jpeg = await Task.detached(priority: .userInitiated, operation: {
                       ImageResizer.jpegData(from: data)
                   }).value {
                    await model.setPhoto(jpeg: jpeg)
                } else {
                    model.photoCouldNotBeRead()
                }
                pickedPhoto = nil
            }
        }
    }

    private var bioError: String? {
        if let serverMessage = model.fieldErrors["bio"] {
            return serverMessage
        }
        return model.bioCharactersLeft < 0 ? "Keep this to \(ProfileFormModel.bioLimit) characters or fewer." : nil
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                ZStack {
                    AvatarView(urlString: model.photoUrl, size: 84)
                    if model.isUploadingPhoto {
                        ProgressView()
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    PhotosPicker(selection: $pickedPhoto, matching: .images) {
                        Text(model.photoUrl == nil ? "Add a photo" : "Change photo")
                    }
                    .buttonStyle(LinkButtonStyle())
                    .disabled(model.isUploadingPhoto)

                    if model.photoUrl != nil {
                        Button("Remove photo") {
                            Task { await model.removePhoto() }
                        }
                        .buttonStyle(LinkButtonStyle())
                        .disabled(model.isUploadingPhoto)
                    }
                }
            }
            if let message = model.photoMessage {
                ErrorText(message)
            } else {
                Text("Optional. A clear photo of you helps listers say yes.")
                    .font(.footnote)
                    .foregroundStyle(Brand.ink.opacity(0.7))
            }
        }
    }
}

/// Shown right after sign-up, until the required answers are in.
@MainActor
struct ProfileSetupView: View {
    @State private var model: ProfileFormModel
    private let user: User
    private let onSignOut: () -> Void

    init(container: AppContainer, user: User) {
        self.user = user
        _model = State(initialValue: container.makeProfileForm(for: user))
        let session = container.session
        self.onSignOut = { Task { await session.signOut() } }
    }

    var body: some View {
        OnboardingPage(
            title: "Tell people who you are.",
            subtitle: "Listers see this before they say yes. You can change it later."
        ) {
            VerifiedBadge(schoolName: user.school.name)
            ProfileFormView(model: model, saveTitle: "Continue")
            Button("Use a different email") { onSignOut() }
                .buttonStyle(LinkButtonStyle())
                .frame(maxWidth: .infinity)
        }
    }
}

/// The edit sheet opened from the Profile tab.
@MainActor
struct ProfileEditView: View {
    @State private var model: ProfileFormModel
    @Environment(\.dismiss) private var dismiss

    init(container: AppContainer, user: User) {
        _model = State(initialValue: container.makeProfileForm(for: user))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ProfileFormView(model: model, saveTitle: "Save") {
                    dismiss()
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Brand.cream)
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Brand.magenta)
                }
            }
        }
    }
}

#Preview("Set up") {
    ProfileSetupView(
        container: .preview(signedInAs: PreviewData.newUser),
        user: PreviewData.newUser
    )
}

#Preview("Edit") {
    ProfileEditView(container: .preview(), user: PreviewData.aditi)
}
