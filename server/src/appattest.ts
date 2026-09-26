/**
 * App Attest checks, following Apple's "Validating apps that connect to your server". An
 * attestation proves a key lives in the Secure Enclave of a real device, inside Tical; an
 * assertion then proves a request came from that key.
 */
import { concat, equal, sha256, utf8, type Bytes } from "./bytes.ts";
import * as CBOR from "./cbor.ts";
import { Certificate } from "./certificate.ts";
import * as DER from "./der.ts";
import { OID, Tag } from "./der.ts";
import { ecPoint, isSigned, verifyECDSA } from "./signing.ts";

export class AppAttestError extends Error {}

export type Environment = "development" | "production";

const developmentAAGUID = utf8("appattestdevelop");
const productionAAGUID = concat([utf8("appattest"), new Uint8Array(7)]);

export interface AttestedKey {
  appId: string;
  /** The key's SubjectPublicKeyInfo, which later assertions are checked against. */
  publicKey: Bytes;
  environment: Environment;
  /** Apple's receipt, which can later be exchanged for a fraud risk metric. */
  receipt: Bytes;
}

export async function verifyAttestation(options: {
  attestation: Bytes;
  /** The one-time challenge the server handed out; the app hashes it into the attestation. */
  challenge: Bytes;
  /** The key identifier from `DCAppAttestService.generateKey()`, decoded from base64. */
  keyId: Bytes;
  /** Team ID and bundle ID, like `ABCDE12345.com.example.app`. */
  appIds: readonly string[];
  root: Certificate;
  now: Date;
  allowDevelopment: boolean;
}): Promise<AttestedKey> {
  const object = read(() => CBOR.fields(CBOR.decode(options.attestation)));
  if (object.fmt !== "apple-appattest") throw new AppAttestError("Not an App Attest attestation.");
  const statement = read(() => CBOR.fields(object.attStmt));
  const x5c = statement.x5c;
  const authData = object.authData;
  const receipt = statement.receipt;
  if (!Array.isArray(x5c) || x5c.length < 2 || !x5c.every((item) => item instanceof Uint8Array)) {
    throw new AppAttestError("The attestation has no certificate chain.");
  }
  if (!(authData instanceof Uint8Array) || !(receipt instanceof Uint8Array)) {
    throw new AppAttestError("The attestation is incomplete.");
  }

  // 1. The certificates chain to Apple's App Attestation root.
  const chain = read(() => (x5c as Bytes[]).map((der) => new Certificate(der)));
  await verifyChain(chain, options.root, options.now);
  const credential = chain[0]!;

  // 2–4. The credential certificate carries a nonce over the authenticator data and the challenge.
  const clientDataHash = await sha256(options.challenge);
  const nonce = await sha256(concat([authData, clientDataHash]));
  if (!equal(certificateNonce(credential), nonce)) throw new AppAttestError("The nonce doesn't match the challenge.");

  // 5. The key identifier is the hash of the credential's public key.
  if (!equal(await sha256(ecPoint(credential.subjectPublicKeyInfo)), options.keyId)) {
    throw new AppAttestError("The key identifier doesn't match the attested key.");
  }

  const data = authenticatorData(authData, true);
  // 6. The key belongs to one of our apps.
  const appId = await matchingAppId(data.rpIdHash, options.appIds);
  // 7. A new key hasn't signed anything yet.
  if (data.counter !== 0) throw new AppAttestError("A new key's counter must be zero.");
  // 8. The environment is production, or development when that's allowed.
  let environment: Environment;
  if (data.aaguid && equal(data.aaguid, productionAAGUID)) {
    environment = "production";
  } else if (data.aaguid && equal(data.aaguid, developmentAAGUID) && options.allowDevelopment) {
    environment = "development";
  } else {
    throw new AppAttestError("The attestation comes from an environment this server doesn't accept.");
  }
  // 9. The credential ID is the key identifier.
  if (!data.credentialId || !equal(data.credentialId, options.keyId)) {
    throw new AppAttestError("The credential ID doesn't match the key identifier.");
  }

  return { appId, publicKey: credential.subjectPublicKeyInfo, environment, receipt };
}

/** Checks an assertion over `clientData` and returns the key's new counter. */
export async function verifyAssertion(options: {
  assertion: Bytes;
  /** The exact bytes the app hashed, which for Tical is the request body. */
  clientData: Bytes;
  publicKey: Bytes;
  appId: string;
  previousCounter: number;
}): Promise<number> {
  const object = read(() => CBOR.fields(CBOR.decode(options.assertion)));
  const { signature, authenticatorData: authData } = object;
  if (!(signature instanceof Uint8Array) || !(authData instanceof Uint8Array)) {
    throw new AppAttestError("The assertion is incomplete.");
  }
  const clientDataHash = await sha256(options.clientData);
  const nonce = await sha256(concat([authData, clientDataHash]));
  if (!(await verifyECDSA(options.publicKey, signature, nonce, "SHA-256"))) {
    throw new AppAttestError("The assertion's signature isn't valid.");
  }
  const data = authenticatorData(authData, false);
  if (!equal(data.rpIdHash, await sha256(utf8(options.appId)))) throw new AppAttestError("The assertion is for another app.");
  if (data.counter <= options.previousCounter) throw new AppAttestError("The assertion was used before.");
  return data.counter;
}

async function verifyChain(chain: Certificate[], root: Certificate, now: Date): Promise<void> {
  const issuers = [...chain.slice(1), root];
  for (const [index, certificate] of chain.entries()) {
    const issuer = issuers[index]!;
    if (!certificate.isValid(now)) throw new AppAttestError("A certificate in the chain has expired or isn't valid yet.");
    if (index > 0 && !certificate.isCertificateAuthority) throw new AppAttestError("An intermediate isn't a certificate authority.");
    if (!(await isSigned(certificate, issuer))) throw new AppAttestError("The chain doesn't lead to Apple's App Attestation root.");
  }
  if (!root.isValid(now)) throw new AppAttestError("Apple's App Attestation root isn't valid.");
}

/** The nonce in extension 1.2.840.113635.100.8.2: `SEQUENCE { [1] { OCTET STRING } }`. */
function certificateNonce(certificate: Certificate): Bytes {
  const extension = certificate.extensions.get(OID.appAttestNonce);
  if (!extension) throw new AppAttestError("The credential certificate has no nonce.");
  return read(() => {
    const [tagged] = DER.children(DER.expect(DER.parse(extension.value), Tag.sequence));
    return DER.expect(DER.children(DER.expect(tagged, 0xa1))[0], Tag.octetString).content;
  });
}

/** WebAuthn authenticator data, as App Attest lays it out. Only attestations carry the credential. */
function authenticatorData(data: Bytes, withCredential: boolean) {
  if (data.length < 37) throw new AppAttestError(`The authenticator data is truncated (${data.length} bytes).`);
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const result = {
    rpIdHash: data.subarray(0, 32),
    counter: view.getUint32(33),
    aaguid: undefined as Bytes | undefined,
    credentialId: undefined as Bytes | undefined,
  };
  // Attested credential data follows only when the AT flag is set, as in an attestation.
  if (withCredential) {
    if (data.length < 55) throw new AppAttestError(`The authenticator data is truncated (${data.length} bytes).`);
    const length = view.getUint16(53);
    if (55 + length > data.length) throw new AppAttestError(`The credential ID is truncated (${data.length} bytes, ID ${length}).`);
    result.aaguid = data.subarray(37, 53);
    result.credentialId = data.subarray(55, 55 + length);
  }
  return result;
}

async function matchingAppId(rpIdHash: Bytes, appIds: readonly string[]): Promise<string> {
  for (const appId of appIds) {
    if (equal(rpIdHash, await sha256(utf8(appId)))) return appId;
  }
  throw new AppAttestError("The key belongs to another app.");
}

/** Runs a parsing step, reporting malformed input as an App Attest failure. */
function read<T>(parse: () => T): T {
  try {
    return parse();
  } catch (error) {
    if (error instanceof AppAttestError) throw error;
    throw new AppAttestError(`The object is malformed: ${error instanceof Error ? error.message : String(error)}`);
  }
}
