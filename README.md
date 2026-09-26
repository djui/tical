# Tical

Tical turns a ticket screenshot or PDF into a calendar event and an Apple Wallet pass. It reads the ticket on the iPhone: Vision finds the code and the text, and Apple Intelligence (or a local parser when it isn't available) fills in the details. You review everything on a live preview of the pass before adding it anywhere.

## Open in Xcode

1. Open `Tical.xcodeproj` in Xcode 27 (the iOS 27 SDK).
2. Select the **Tical** scheme.
3. Set your Development Team on the Tical, TicalShare, and TicalTests targets.
4. Run on an iPhone or a simulator with iOS 27.

There are no Swift packages and no third-party dependencies. The project uses Swift 6 with main-actor default isolation.

Run the tests with **Product ▸ Test**, or:

```sh
xcodebuild test -project Tical.xcodeproj -scheme Tical -destination 'platform=iOS Simulator,name=iPhone 17'
```

## What the app does

1. Pick a screenshot or photo, choose a file (an image or a PDF), paste, drag and drop, or share to Tical from Photos, Files, Mail, or Safari. For a PDF, Tical uses the first page that carries a code.
2. Vision reads the code (QR, Aztec, PDF417, Code 128, Data Matrix) and the text. Binary QR codes are decoded to their bytes, so the pass carries the same content.
3. Apple Intelligence reads the ticket image and its text into fields. If the model isn't available, doesn't answer within 20 seconds, or fails, the local parser (English and German labels, `NSDataDetector`) fills them in. Codes the model reports are only kept if they're printed on the ticket.
4. The review screen shows the pass as Wallet will show it, in a color taken from the ticket. Every field can be edited.
5. **Calendar** opens the system event editor, filled in. The editor runs outside Tical, so Tical needs no calendar access and never sees your other events.
6. **Add to Wallet** builds and signs the pass on the iPhone and shows the system sheet to add it. Tical redraws the code and reads it back before offering it, and says so when it can't confirm a match.

## Wallet passes

Wallet only accepts passes signed with a **Pass Type ID certificate** from Apple, which needs an Apple Developer Program membership. Tical does the signing itself, on the iPhone: it builds the `.pkpass`, hashes its files into `manifest.json`, and signs that with a CMS signature (SHA-256, RSA) that includes Apple's WWDR intermediate certificate.

Set it up once in **Settings ▸ Wallet Passes**:

1. **Create Request.** Tical makes an RSA key in the iPhone's keychain and a certificate signing request for it. The key never leaves the device (it's excluded from backups and iCloud Keychain).
2. In the Apple Developer account, register a Pass Type ID, create a **Pass Type ID certificate** for it, and upload the request.
3. **Import Certificate**: pick the `pass.cer` file Apple returns.

If you already have a Pass Type ID certificate on a Mac, export it with its private key from Keychain Access as a `.p12` file and use **Import .p12 File** instead.

A certificate file without Apple's intermediate certificate makes iOS download that public certificate once, from the address in the certificate. A PEM file that includes the intermediate works offline.

On iPad, which has no Wallet, the button sends the signed pass to another device instead. **Share Pass File** in the review screen's menu does the same on iPhone.

Passes are static: there is no web service to update them.

## Share extension and App Group

Both targets use the App Group `group.com.tical.app`. The share extension saves the shared file in the group's `Inbox` folder and opens `tical://import`; the app reads the newest file and clears the folder.

Register the group for the App IDs `com.tical.app` and `com.tical.app.share`. If you change the bundle IDs, keep the group identifier in sync in `TicketDefaults` (app) and `ShareHandoff` (extension).

Share extensions can't open URLs through `NSExtensionContext`, so the extension asks the app object in its responder chain to open `tical://import`. If that ever stops working, the ticket still waits in the inbox and the extension says to open Tical.

## Permissions and privacy

Tical asks for no permissions. The Photos picker, the Files picker, the paste button, and the Calendar editor all run outside the app.

Tickets are read on the device and never uploaded. The only network access is iOS fetching Apple's public intermediate certificate during Wallet setup, when the certificate file doesn't include it. The privacy manifest declares user defaults (the two settings below) and file timestamps (picking the newest shared file).

## Settings

- **Length**: how long an event lasts when the ticket prints no end. Default 2 hours.
- **Start for date-only tickets**: the start time when a ticket prints a date but no time. Default 7:00 PM.

## Testing in the simulator

- Apple Intelligence doesn't run in the simulator, so imports there always use the local parser.
- The simulator's current barcode detector fails, so simulator builds use Vision's first barcode revision.
- To import without the pickers, copy an image or PDF into the App Group's `Inbox` folder and open `tical://import`:

  ```sh
  GROUP=$(xcrun simctl get_app_container booted com.tical.app group.com.tical.app)
  mkdir -p "$GROUP/Inbox" && cp ticket.png "$GROUP/Inbox/"
  xcrun simctl openurl booted tical://import
  ```

- To try the Wallet flow without an Apple certificate, make a test CA with OpenSSL, issue a certificate for the request from **Create Request** with the subject `/UID=pass.example/CN=Pass Type ID: pass.example/OU=TEAMID/O=Example/C=US`, and import it as a PEM file that includes the test intermediate. Tical signs passes with it, and `openssl cms -verify` accepts them against the test root. Wallet itself rejects them, since only Apple's CA is trusted.

## Code layout

- `Import/`: files from pickers and the share extension; PDF pages and image decoding.
- `Scanning/`: Vision, the language model, the local parser, and the pass color.
- `Wallet/`: pass building and signing (DER, X.509, CMS, PKCS #10, ZIP), the keychain, and certificate setup.
- `Calendar/`: the event and the system editor.
- `Views/`: SwiftUI screens.
