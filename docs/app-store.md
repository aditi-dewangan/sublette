# App Store and TestFlight

Everything needed to put Sublette on TestFlight and then the App Store. The
steps marked **(Aditi)** need her Apple Developer account, which costs $99 a
year; nothing here has been paid for or submitted.

## The listing

| Field | Text |
| --- | --- |
| Name | Sublette: College Sublets |
| Subtitle (30 characters) | Swipe, match, sublet. |
| Category | Lifestyle (no secondary category) |
| Age rating | 17+ is not needed. Answer "Unrestricted web access: No", "User-generated content: Yes" (Apple then checks for reporting and blocking, which phase 8 added). The terms set 18 as the minimum age. |
| Price | Free, no in-app purchases |
| Support URL | `https://<server>/terms` until there is a website |
| Privacy policy URL | `https://<server>/privacy` |
| Copyright | 2026 Sublette |

**Promotional text (170 characters):** Students only. Find a room for your
internship or summer term, or hand yours over while you're away. Every account
is checked with a school email.

**Description:**

> Sublette is the sublet app for college students.
>
> Going away for an internship, a semester abroad or the summer? Post your
> room, choose who can take it, and swipe on the students who liked it.
>
> Need a place for a few months? Set your dates, budget and must-haves, drop
> a pin where you want to live, and swipe on rooms that fit. When you both
> like each other it's a match, and you can chat, tour, and tick off the
> steps to a sublet together.
>
> - Only verified students: every account signs in with a school (.edu) email.
> - Your exact address stays private until you match.
> - Must-haves are never broken: no pets, no smoking, private bathroom, your
>   budget. You only see places that fit.
> - A map of every place that fits, with your matches pinned.
> - A shared checklist: tour done, landlord's consent, dates agreed, sublease
>   signed.
> - Report and block anyone, any time. Sublette never asks for payment;
>   rent is agreed between you.

**Keywords (100 characters):** sublet,sublease,college,student,housing,room,roommate,internship,summer,apartment

## Privacy label (App Store Connect → App Privacy)

These must match `ios/Sublette/Resources/PrivacyInfo.xcprivacy`. Sublette
does **not track** anyone and has no third-party SDKs.

| Data type | Collected | Linked to the person | Used for |
| --- | --- | --- | --- |
| Email address | Yes | Yes | App functionality (sign-in) |
| Name (first name) | Yes | Yes | App functionality |
| Photos | Yes | Yes | App functionality (profile and listing photos) |
| Precise location | Yes | Yes | App functionality (the renter's pin, a listing's address; never the phone's GPS) |
| Emails or text messages | Yes | Yes | App functionality (chat) |
| Other user content | Yes | Yes | App functionality (listings, bio, reports) |
| User ID | Yes | Yes | App functionality |
| Other data (year, program, gender, smoking, pets) | Yes | Yes | App functionality |
| Product interaction | Yes | Yes | Analytics (feature use, app opens) |
| Crash data | Yes | Yes | App functionality (crash reports from MetricKit) |

Not collected: contacts, health, financial info, payment info, browsing
history, search history, device location from GPS, advertising data.

## Screenshots

Apple needs 6.9-inch iPhone screenshots (1320 × 2868). Take them in the
iPhone 16 Pro Max simulator with `make dev` and `make seed-fake` running,
using **File → Save Screen Shot** (⌘S) in the Simulator:

1. The renter deck with a "Great fit" card.
2. The map with pins and the circle.
3. The match moment.
4. A chat with the checklist open.
5. The lister's listing with "Share this listing".
6. Lister mode: renters who liked the listing.

## TestFlight (Aditi)

1. Join the Apple Developer Program ($99 a year) at developer.apple.com.
2. In App Store Connect, create the app with bundle id `app.sublette.Sublette`.
3. Deploy staging (README, "Staging, for $0") and put its address in
   `ios/project.yml` under `Release` → `SUBLETTE_API_BASE_URL`.
4. In Xcode: select "Any iOS Device", then **Product → Archive**, then
   **Distribute App → App Store Connect**.
5. In App Store Connect → TestFlight, add 20 to 50 UW students as external
   testers with a link. External testing needs a short Beta App Review.
6. Watch the admin page's **Numbers** (`/admin/metrics`) for two weeks:
   sign-ups to matches, and crash-free sessions (the goal is above 99%).
7. Fix what testers hit, then submit for App Store review with the listing
   above.
