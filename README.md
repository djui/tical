# Tical

Tical turns a ticket screenshot into a calendar event. It reads the image on the iPhone: Vision finds the barcode and the text, then either the on-device system model or a local parser fills in the fields. You can edit every field before saving.

Wallet is not fully available. Apple still requires a signed `.pkpass`, and this app does not create one. The review screen explains that, and it shows the code that was read.

## Open in Xcode

1. On a Mac, open `Tical.xcodeproj` in Xcode 27 (the iOS 27 SDK).
2. Select the **Tical** scheme.
3. Set your Development Team on **both** the Tical app target and the TicalShare extension (Signing & Capabilities).
4. Run on an iPhone or simulator with iOS 27.

Deployment target is **iOS 27.0**. There are no Swift packages and no third-party dependencies.

This project was written without an Xcode build on the machine that produced it. The first build has to happen in Xcode.

## Capabilities

Both targets use one App Group:

`group.com.tical.app`

Register that group for the App IDs `com.tical.app` and `com.tical.app.share` (Certificates, Identifiers & Profiles, or Xcode’s Signing & Capabilities). The share extension writes the screenshot into that container and opens `tical://import`. The app target registers the `tical` URL scheme.

No Push Notifications, iCloud, Associated Domains, or Wallet entitlement. No network client entitlement and no App Transport Security exceptions. The app does not call `URLSession`.

Change the bundle IDs in the target build settings if `com.tical.app` is already taken, and keep the App Group and the two copies of its identifier in sync (`TicketDefaults` in the app, `ShareHandoff` in the extension).

## Permissions

The app target asks for:

- **Photo library** (`NSPhotoLibraryUsageDescription`). The Photos picker is how you choose a screenshot. The system may not show a prompt for the picker itself; the string is there when it does.
- **Calendar write-only** (`NSCalendarsWriteOnlyAccessUsageDescription`). Tical adds one event and does not read other events. The older `NSCalendarsUsageDescription` key is also set, which is the fallback Apple documents in TN3153.

The share extension does not request the photo library. It receives the image from the share sheet.

## What the app does

1. Choose a screenshot, or share an image to Tical from Photos.
2. On device, `VNDetectBarcodesRequest` looks for QR, PDF417, Aztec, Data Matrix, and Code 128. `VNRecognizeTextRequest` reads the text.
3. If `SystemLanguageModel` is available, Tical asks that on-device model for structured fields. It does not call Private Cloud Compute or any other service. If the model is unavailable or the request fails, a local parser uses `NSDataDetector` and English/German labels. You can edit the result either way.
4. **Add to Calendar** saves an event on the default calendar. Notes include the confirmation code when there is one. If the end is missing or not after the start, the event lasts **2 hours**.
5. **Add to Wallet** opens an explanation. It calls `PKAddPassesViewController.canAddPasses()` so the text can say whether this device can add passes at all. It does not build a `.pkpass`.

## Defaults

- A printed date with no clock time is shown as **7:00 PM** local time, marked as assumed.
- A missing end time is shown as start plus 2 hours, and Calendar enforces that same duration.
- A short barcode payload is copied into the confirmation field when no labeled code was found. A URL, or a payload longer than 20 characters, is not.
- Dates with a `.` are read as day.month.year. Slash dates follow the device locale (day-first, except `en_US`).
- Clock times without am/pm are kept as printed (`19:00` stays 19:00; `7:00` stays 07:00). Change them on the review screen if the ticket meant evening.

## Wallet signing

Fully local Wallet creation is not possible.

Wallet only accepts a pass signed with an Apple-issued Pass Type ID certificate and the WWDR intermediate certificate. PassKit can present a pass that is already signed (`PKPass`, `PKAddPassesViewController`). It cannot make the signature. WWDC26 Pass Builder (`PassSigner`) still needs those certificates, and it runs on a Mac or a server, not as an on-device API. Tical does not embed a private key and does not include a signing server.

You do **not** need a Pass Type ID to use import, review, or Calendar.

To produce a real pass later, outside this app: register a Pass Type ID, create a Pass Type ID certificate in Certificates, Identifiers & Profiles, keep the private key off the phone, and sign with Pass Builder or another signer you control. Do not paste that key into Tical.
