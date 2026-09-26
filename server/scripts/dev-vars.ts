/**
 * Writes .dev.vars, the secrets `wrangler dev` uses. It also turns on unattested signing,
 * because the iOS simulator can't use App Attest.
 *
 *   npm run dev-vars
 *       Makes a throwaway certificate. Wallet rejects its passes, but everything else works.
 *   npm run dev-vars -- --key .secrets/signing-key.pem --certificate .secrets/pass.cer
 *       Uses your key and the Pass Type ID certificate Apple issued for it.
 */
import { createPrivateKey } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { pem } from "../src/bytes.ts";
import { Certificate } from "../src/certificate.ts";
import { bytes, passSigningChain } from "./pki.ts";

const { values } = parseArgs({ options: { key: { type: "string" }, certificate: { type: "string" } } });

let key: string;
let certificates: string;
if (values.key && values.certificate) {
  key = createPrivateKey(readFileSync(values.key)).export({ type: "pkcs8", format: "pem" }).toString();
  const file = readFileSync(values.certificate);
  const certificate = file.includes("-----BEGIN") ? file.toString("utf8") : pem(bytes(file), "CERTIFICATE");
  const passType = Certificate.fromPEM(certificate)[0]?.passTypeIdentifier;
  if (!passType) throw new Error(`${values.certificate} isn't a Pass Type ID certificate.`);
  certificates = certificate + readFileSync(new URL("../certificates/AppleWWDRCAG4.pem", import.meta.url), "utf8");
  console.log(`Signing as ${passType}.`);
} else if (values.key || values.certificate) {
  throw new Error("Pass both --key and --certificate, or neither.");
} else {
  const chain = passSigningChain();
  key = chain.passKey.export({ type: "pkcs8", format: "pem" }).toString();
  certificates = pem(chain.pass, "CERTIFICATE") + pem(chain.authority, "CERTIFICATE");
  console.log("Signing with a throwaway certificate for pass.dev.tical. Wallet won't accept its passes.");
}

// Double-quoted values with \n escapes, which wrangler reads as multi-line values.
writeFileSync(
  new URL("../.dev.vars", import.meta.url),
  [
    "# Written by `npm run dev-vars` for `wrangler dev`. Never commit this file.",
    'ALLOW_UNATTESTED="true"',
    `SIGNING_KEY=${JSON.stringify(key)}`,
    `SIGNING_CERTIFICATES=${JSON.stringify(certificates)}`,
    "",
  ].join("\n"),
  { mode: 0o600 },
);
console.log("Wrote .dev.vars.");
