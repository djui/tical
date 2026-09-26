# Tical signing server

Wallet only accepts passes signed with a Pass Type ID certificate from Apple. This
Cloudflare Worker signs Tical's passes with Tical's certificate, so people don't need
an Apple Developer account of their own.

## What it sees

The app builds the whole pass on the device, then sends only the SHA-256 digest of its
`manifest.json`, which is a list of file hashes. The server wraps that digest in a CMS
signature with the current time, signs it, and returns the pass's `signature` file. No
ticket details reach the server.

To keep strangers from signing their own passes under Tical's name, every request
comes from an [App Attest](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)
key. That proves the request came from Tical on a real device. The server stores each
key's public key and counter, and counts signatures per key per day. It doesn't store
IP addresses, request bodies, or anything that identifies a person.

| Endpoint | |
| --- | --- |
| `GET /v1/pass-type` | The pass type and team a pass must name to match the certificate |
| `POST /v1/challenges` | A one-time challenge for registering an App Attest key |
| `POST /v1/keys` | Registers a key: `{ keyId, challenge, attestation }` |
| `POST /v1/signatures` | Signs `{ keyId, manifestDigest }`, with an App Attest assertion over the exact body in `X-Tical-Assertion` |

Limits are set in `wrangler.jsonc`: 30 signatures per key per day, 5,000 in total per
day, and 2,000 new keys per day.

## Code

- `src/index.ts`: the Worker: configuration, HTTP, and a daily cleanup.
- `src/service.ts`: the endpoints and their checks.
- `src/appattest.ts`: App Attest attestations and assertions, as Apple documents them.
- `src/cms.ts`: the pass signature, the same structure as the app's `CMSSignature.swift`.
- `src/der.ts`, `src/cbor.ts`, `src/certificate.ts`: just enough ASN.1, CBOR, and X.509.
- `src/d1.ts`, `migrations/`: keys, challenges, and counts in D1.
- `certificates/`: Apple's public WWDR G4 intermediate and App Attestation root.

Signing and verification use Web Crypto, so the same code runs in the Worker and in
Node's test runner. There are no runtime dependencies.

## Develop

Requires Node 22.18 or later.

```sh
npm install
npm test
npm run typecheck
```

To run the Worker locally, for the iOS simulator:

```sh
npm run dev-vars
npx wrangler d1 migrations apply tical-signing --local
npm run dev
```

`npm run dev-vars` writes `.dev.vars` with a throwaway certificate. Wallet rejects its
passes, but everything up to that point works. It also allows requests without App
Attest, which the simulator can't do. Never set `ALLOW_UNATTESTED` in production.

Then launch Tical against it:

```sh
xcrun simctl launch booted com.tical.app -TicalSigningServiceURL http://127.0.0.1:8787
```

The app uses your own certificate instead if you've set one up in Settings. To run
the app's integration test against the local server:

```sh
TEST_RUNNER_TICAL_SIGNING_SERVICE_URL=http://127.0.0.1:8787 xcodebuild test -project ../Tical.xcodeproj -scheme Tical -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:TicalTests/SigningServerIntegrationTests
```

## The signing certificate

The server needs its own Pass Type ID certificate and private key.

1. Make a key and a certificate signing request. The `.secrets` folder is ignored by git:

   ```sh
   mkdir -p .secrets
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out .secrets/signing-key.pem
   openssl req -new -key .secrets/signing-key.pem -subj "/CN=Tical Pass Signing" -out .secrets/Tical.certSigningRequest
   ```

2. In your Apple Developer account, under [Certificates](https://developer.apple.com/account/resources/certificates/add),
   create a **Pass Type ID Certificate** for `pass.com.tical.app` from that request, and
   save the download as `.secrets/pass.cer`.

3. To try it locally first, where Wallet accepts its passes:

   ```sh
   npm run dev-vars -- --key .secrets/signing-key.pem --certificate .secrets/pass.cer
   ```

The certificate is valid for about 13 months. Renew it before it expires the same way,
then update the secrets.

## Deploy

```sh
npx wrangler login
npx wrangler d1 create tical-signing
```

Add the printed `database_id` to `wrangler.jsonc`, then:

```sh
npx wrangler d1 migrations apply tical-signing --remote
npx wrangler secret put SIGNING_KEY < .secrets/signing-key.pem
openssl x509 -inform DER -in .secrets/pass.cer | cat - certificates/AppleWWDRCAG4.pem | npx wrangler secret put SIGNING_CERTIFICATES
npm run deploy
```

Set the Worker's URL, like `https://tical-signing.<your-subdomain>.workers.dev`, as
`TICAL_SIGNING_SERVICE_URL` in the Tical target's build settings.

The private key is now a Cloudflare secret, readable only by the Worker. You can
delete the local copy: if you ever need a new key, make a new certificate. If the key
leaks, revoke the certificate in your developer account.

`ALLOW_DEVELOPMENT_ATTESTATION` accepts apps that Xcode installs. TestFlight and App
Store builds always use the production App Attest environment, so set it to `"false"`
once you no longer need Xcode builds against this server.
