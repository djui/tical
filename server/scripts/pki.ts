/**
 * Throwaway certificates for tests and `wrangler dev`, built with Node's crypto. They're
 * shaped like Apple's, but Wallet and App Attest only trust Apple's own.
 */
import { generateKeyPairSync, sign, type KeyObject } from "node:crypto";
import type { Bytes } from "../src/bytes.ts";
import * as DER from "../src/der.ts";
import { OID, Tag } from "../src/der.ts";

export interface KeyPair {
  privateKey: KeyObject;
  publicKey: KeyObject;
}

export function rsaKeys(): KeyPair {
  return generateKeyPairSync("rsa", { modulusLength: 2048 });
}

export function ecKeys(curve: "P-256" | "P-384"): KeyPair {
  return generateKeyPairSync("ec", { namedCurve: curve === "P-256" ? "prime256v1" : "secp384r1" });
}

export function name(attributes: [oid: string, value: string][]): Bytes {
  return DER.sequence(
    attributes.map(([oid, value]) => DER.set([DER.sequence([DER.objectIdentifier(oid), DER.utf8String(value)])])),
  );
}

export function extension(oid: string, value: Bytes, critical = false): Bytes {
  return DER.sequence([DER.objectIdentifier(oid), ...(critical ? [DER.boolean(true)] : []), DER.octetString(value)]);
}

/** Basic constraints and key usage for a certificate authority. */
export const authorityExtensions = [
  extension(OID.basicConstraints, DER.sequence([DER.boolean(true)]), true),
  extension(OID.keyUsage, DER.tlv(Tag.bitString, Uint8Array.of(1, 0x06)), true), // keyCertSign, cRLSign
];

/** Key usage for a signing certificate. */
export const signingExtensions = [extension(OID.keyUsage, DER.tlv(Tag.bitString, Uint8Array.of(7, 0x80)), true)];

export function certificate(options: {
  subject: Bytes;
  issuer: Bytes;
  publicKey: KeyObject;
  signingKey: KeyObject;
  serial?: number;
  notBefore?: Date;
  notAfter?: Date;
  extensions?: Bytes[];
}): Bytes {
  const rsa = options.signingKey.asymmetricKeyType === "rsa";
  const large = options.signingKey.asymmetricKeyDetails?.namedCurve === "secp384r1";
  const algorithm = rsa
    ? DER.algorithmIdentifier(OID.sha256WithRSAEncryption)
    : DER.algorithmIdentifier(large ? OID.ecdsaWithSHA384 : OID.ecdsaWithSHA256, false);
  const notBefore = options.notBefore ?? new Date(Date.now() - 3_600_000);
  const notAfter = options.notAfter ?? new Date(Date.now() + 365 * 86_400_000);
  const tbs = DER.sequence([
    DER.context(0, DER.integer(2)),
    DER.integer(options.serial ?? Math.floor(Math.random() * 2 ** 40)),
    algorithm,
    options.issuer,
    DER.sequence([DER.utcTime(notBefore), DER.utcTime(notAfter)]),
    options.subject,
    bytes(options.publicKey.export({ type: "spki", format: "der" })),
    ...(options.extensions?.length ? [DER.context(3, DER.sequence(options.extensions))] : []),
  ]);
  const signature = bytes(sign(rsa ? "sha256" : large ? "sha384" : "sha256", tbs, options.signingKey));
  return DER.sequence([tbs, algorithm, DER.bitString(signature)]);
}

/** A Pass Type ID certificate from a made-up authority, with its private key. */
export function passSigningChain(passTypeIdentifier = "pass.dev.tical", team = "DEVTEAM001") {
  const authorityKeys = rsaKeys();
  const authorityName = name([
    [OID.commonName, "Tical Development Authority"],
    [OID.organizationName, "Tical Development"],
  ]);
  const authority = certificate({
    subject: authorityName,
    issuer: authorityName,
    publicKey: authorityKeys.publicKey,
    signingKey: authorityKeys.privateKey,
    extensions: authorityExtensions,
  });
  const passKeys = rsaKeys();
  const pass = certificate({
    subject: name([
      [OID.userID, passTypeIdentifier],
      [OID.commonName, `Pass Type ID: ${passTypeIdentifier}`],
      [OID.organizationalUnitName, team],
      [OID.organizationName, "Tical Development"],
    ]),
    issuer: authorityName,
    publicKey: passKeys.publicKey,
    signingKey: authorityKeys.privateKey,
    extensions: signingExtensions,
  });
  return { authority, pass, passKey: passKeys.privateKey };
}

export function bytes(buffer: Buffer): Bytes {
  return new Uint8Array(buffer);
}
