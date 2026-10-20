import SwiftUI

/// The five lifestyle questions, worded for the renter ("you") or for the
/// housemates staying ("they"). Every one can be left unanswered.
@MainActor
struct HomeLifeQuestions: View {
    enum About {
        case me
        case housemates
    }

    @Binding var answers: HomeLife
    let about: About

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            question(about == .me ? "When do you sleep?" : "When do they sleep?",
                     selection: $answers.sleepSchedule)
            question(about == .me ? "How tidy are you?" : "How tidy is the home?",
                     selection: $answers.tidiness)
            question(about == .me ? "How often do you have guests?" : "How often do they have guests?",
                     selection: $answers.guests)
            question(about == .me ? "Do you work or study at home?" : "Are they home during the day?",
                     selection: $answers.homeDaytime)
            question(about == .me ? "Quiet or social home?" : "Is it a quiet or social home?",
                     selection: $answers.homeVibe)
        }
    }

    private func question<Answer: CaseIterable & Identifiable & Hashable>(
        _ title: String,
        selection: Binding<Answer?>
    ) -> some View where Answer.AllCases: RandomAccessCollection, Answer: Titled {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink)
            Picker(title, selection: selection) {
                Text("Skip").tag(Answer?.none)
                ForEach(Answer.allCases) { answer in
                    Text(answer.title).tag(Answer?.some(answer))
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// Anything with a title to show in a picker.
protocol Titled {
    var title: String { get }
}

extension SleepSchedule: Titled {}
extension Tidiness: Titled {}
extension HowOften: Titled {}
extension HomeVibe: Titled {}

#Preview {
    @Previewable @State var answers = HomeLife(sleepSchedule: .early)
    return HomeLifeQuestions(answers: $answers, about: .me)
        .padding()
        .background(Brand.cream)
}
