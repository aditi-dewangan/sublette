import Foundation
import Observation

/// The profile form, used both right after sign-up and when editing later.
@MainActor
@Observable
final class ProfileFormModel {
    var firstName: String
    var year: Year?
    var program: String
    var bio: String
    /// Optional. Nil means "prefer not to say".
    var gender: Gender?
    var smokes: Bool?
    var hasPets: Bool?

    private(set) var photoUrl: String?
    private(set) var isSaving = false
    private(set) var isUploadingPhoto = false
    private(set) var errorMessage: String?
    /// What happened to the photo, when it could not be uploaded or removed.
    private(set) var photoMessage: String?
    /// Messages from the server, keyed by its field names such as `first_name`.
    private(set) var fieldErrors: [String: String] = [:]

    private let api: AccountAPI
    private let uploader: PhotoUploading
    private let session: SessionModel

    static let bioLimit = 160

    init(user: User, api: AccountAPI, uploader: PhotoUploading, session: SessionModel) {
        self.api = api
        self.uploader = uploader
        self.session = session
        self.firstName = user.firstName ?? ""
        self.program = user.program ?? ""
        self.bio = user.bio ?? ""
        self.year = user.year
        self.gender = user.gender
        self.smokes = user.smokes
        self.hasPets = user.hasPets
        self.photoUrl = user.photoUrl
    }

    private var trimmedFirstName: String {
        firstName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedProgram: String {
        program.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBio: String {
        bio.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var bioCharactersLeft: Int {
        Self.bioLimit - trimmedBio.count
    }

    /// The answers, if every required one is in. Photo, bio and gender are optional.
    var update: ProfileUpdate? {
        guard !trimmedFirstName.isEmpty, !trimmedProgram.isEmpty, bioCharactersLeft >= 0,
              let year, let smokes, let hasPets
        else {
            return nil
        }
        return ProfileUpdate(
            firstName: trimmedFirstName,
            year: year,
            program: trimmedProgram,
            bio: trimmedBio.isEmpty ? nil : trimmedBio,
            gender: gender,
            smokes: smokes,
            hasPets: hasPets
        )
    }

    var canSave: Bool {
        update != nil && !isSaving
    }

    /// Saves the profile. Returns true when it was saved.
    @discardableResult
    func save() async -> Bool {
        guard let update, !isSaving else {
            return false
        }
        isSaving = true
        errorMessage = nil
        fieldErrors = [:]
        defer { isSaving = false }
        do {
            let user = try await api.updateProfile(update)
            session.update(user)
            return true
        } catch let error as APIError {
            if case .cancelled = error {
                return false
            }
            fieldErrors = error.fieldMessages
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = APIError.unreachable.userMessage
            return false
        }
    }

    /// Uploads a new photo and attaches it. A failure here never blocks the
    /// rest of the profile: the photo is optional and can be added later.
    func setPhoto(jpeg: Data) async {
        guard !isUploadingPhoto else {
            return
        }
        isUploadingPhoto = true
        photoMessage = nil
        defer { isUploadingPhoto = false }
        do {
            let key = try await uploader.uploadProfilePhoto(jpeg)
            let user = try await api.setPhoto(key: key)
            photoUrl = user.photoUrl
            session.update(user)
        } catch let error as APIError {
            switch error {
            case .cancelled:
                break
            case .server(_, _, let message, _):
                photoMessage = message
            default:
                photoMessage = PhotoUploader.failureMessage
            }
        } catch {
            photoMessage = PhotoUploader.failureMessage
        }
    }

    func removePhoto() async {
        guard !isUploadingPhoto, photoUrl != nil else {
            return
        }
        isUploadingPhoto = true
        photoMessage = nil
        defer { isUploadingPhoto = false }
        do {
            let user = try await api.setPhoto(key: nil)
            photoUrl = user.photoUrl
            session.update(user)
        } catch {
            photoMessage = "Couldn't remove the photo. Try again."
        }
    }

    /// The picked file was not an image the phone could read.
    func photoCouldNotBeRead() {
        photoMessage = "That photo couldn't be read. Try a different one."
    }
}
