/** Signing and signature checks with Web Crypto, which Workers and Node both provide. */
import { concat, pemBlocks, utf8, type Bytes } from "./bytes.ts";
import type { Certificate } from "./certificate.ts";
import * as DER from "./der.ts";
import { OID, Tag } from "./der.ts";

/** Signs with RSA PKCS #1 v1.5 and SHA-256, as a pass signature needs. */
export interface Signer {
  sign(data: Bytes): Promise<Bytes>;
}

/** A signer for an RSA private key in PKCS #8 PEM (`-----BEGIN PRIVATE KEY-----`). */
export async function rsaSigner(privateKeyPEM: string): Promise<Signer> {
  const der = pemBlocks(privateKeyPEM, "PRIVATE KEY")[0];
  if (!der) throw new Error("The signing key isn't a PKCS #8 PEM private key (-----BEGIN PRIVATE KEY-----).");
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  return {
    async sign(data) {
      return new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, data));
    },
  };
}

/** Checks that the signer holds the private key for the certificate, before any pass depends on it. */
export async function signerMatches(signer: Signer, certificate: Certificate): Promise<boolean> {
  const probe = utf8("Tical checks its signing key");
  const signature = await signer.sign(probe);
  try {
    const key = await crypto.subtle.importKey(
      "spki",
      certificate.subjectPublicKeyInfo,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    return await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, probe);
  } catch {
    return false;
  }
}

type Curve = "P-256" | "P-384";

/** Verifies an ECDSA signature in DER form, as Apple's certificates and App Attest produce it. */
export async function verifyECDSA(
  subjectPublicKeyInfo: Bytes,
  signature: Bytes,
  data: Bytes,
  hash: "SHA-256" | "SHA-384",
): Promise<boolean> {
  const curve = ecCurve(subjectPublicKeyInfo);
  if (!curve) return false;
  let raw: Bytes;
  try {
    raw = rawSignature(signature, curve === "P-256" ? 32 : 48);
  } catch {
    return false;
  }
  const key = await crypto.subtle.importKey("spki", subjectPublicKeyInfo, { name: "ECDSA", namedCurve: curve }, false, ["verify"]);
  return crypto.subtle.verify({ name: "ECDSA", hash }, key, raw, data);
}

/** Whether `issuer` signed `certificate`. Only ECDSA is needed, for App Attest's chain. */
export async function isSigned(certificate: Certificate, issuer: Certificate): Promise<boolean> {
  if (!certificate.isIssuedBy(issuer)) return false;
  const hash =
    certificate.signatureAlgorithm === OID.ecdsaWithSHA256 ? "SHA-256"
    : certificate.signatureAlgorithm === OID.ecdsaWithSHA384 ? "SHA-384"
    : undefined;
  return hash !== undefined && verifyECDSA(issuer.subjectPublicKeyInfo, certificate.signature, certificate.tbs, hash);
}

/** The public point of an EC key, `04 || x || y`, from its SubjectPublicKeyInfo. */
export function ecPoint(subjectPublicKeyInfo: Bytes): Bytes {
  const [, key] = DER.children(DER.expect(DER.parse(subjectPublicKeyInfo), Tag.sequence));
  return DER.expect(key, Tag.bitString).content.subarray(1);
}

function ecCurve(subjectPublicKeyInfo: Bytes): Curve | undefined {
  try {
    const [algorithm] = DER.children(DER.parse(subjectPublicKeyInfo));
    const [type, parameters] = DER.children(DER.expect(algorithm, Tag.sequence));
    if (DER.objectIdentifierString(DER.expect(type, Tag.objectIdentifier).content) !== OID.ecPublicKey) return undefined;
    const curve = DER.objectIdentifierString(DER.expect(parameters, Tag.objectIdentifier).content);
    return curve === OID.prime256v1 ? "P-256" : curve === OID.secp384r1 ? "P-384" : undefined;
  } catch {
    return undefined;
  }
}

/** Converts `SEQUENCE { r INTEGER, s INTEGER }` to the `r || s` form Web Crypto verifies. */
function rawSignature(der: Bytes, size: number): Bytes {
  const parts = DER.children(DER.expect(DER.parse(der), Tag.sequence));
  if (parts.length !== 2) throw new DER.DERError("An ECDSA signature has two integers.");
  return concat(
    parts.map((part) => {
      let value = DER.expect(part, Tag.integer).content;
      while (value.length > 1 && value[0] === 0) value = value.subarray(1);
      if (value.length > size) throw new DER.DERError("ECDSA integer too long.");
      return concat([new Uint8Array(size - value.length), value]);
    }),
  );
}
