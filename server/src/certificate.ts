import { equal, pemBlocks, type Bytes } from "./bytes.ts";
import * as DER from "./der.ts";
import { OID, Tag } from "./der.ts";

export interface Extension {
  readonly critical: boolean;
  /** The contents of the extension's OCTET STRING: the DER encoding of its value. */
  readonly value: Bytes;
}

/**
 * The parts of an X.509 certificate that signing and App Attest read. A Pass Type ID
 * certificate names the pass type in its subject `UID` and the team in its subject `OU`.
 */
export class Certificate {
  readonly der: Bytes;
  /** The signed part of the certificate. */
  readonly tbs: Bytes;
  /** The full DER encoding of the serial number INTEGER, as CMS needs it. */
  readonly serialNumber: Bytes;
  /** The full DER encoding of the issuer Name, as CMS needs it. */
  readonly issuer: Bytes;
  readonly subject: Bytes;
  readonly subjectAttributes: ReadonlyMap<string, string>;
  readonly notBefore: Date;
  readonly notAfter: Date;
  readonly subjectPublicKeyInfo: Bytes;
  readonly signatureAlgorithm: string;
  readonly signature: Bytes;
  readonly extensions: ReadonlyMap<string, Extension>;

  constructor(der: Bytes) {
    const [tbsNode, algorithm, signature] = DER.children(DER.expect(DER.parse(der), Tag.sequence));
    let fields = DER.children(DER.expect(tbsNode, Tag.sequence));
    if (fields[0]?.tag === 0xa0) fields = fields.slice(1); // [0] EXPLICIT version
    // serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo, then optional fields.
    const [serial, , issuer, validity, subject, publicKeyInfo, ...rest] = fields;
    const [notBefore, notAfter] = DER.children(DER.expect(validity, Tag.sequence));
    const starts = notBefore && DER.dateValue(notBefore);
    const ends = notAfter && DER.dateValue(notAfter);
    if (!starts || !ends) throw new DER.DERError("Unreadable validity dates.");

    this.der = der;
    this.tbs = tbsNode!.encoded;
    this.serialNumber = DER.expect(serial, Tag.integer).encoded;
    this.issuer = DER.expect(issuer, Tag.sequence).encoded;
    this.subject = DER.expect(subject, Tag.sequence).encoded;
    this.subjectAttributes = attributes(subject!);
    this.notBefore = starts;
    this.notAfter = ends;
    this.subjectPublicKeyInfo = DER.expect(publicKeyInfo, Tag.sequence).encoded;
    this.signatureAlgorithm = DER.objectIdentifierString(
      DER.expect(DER.children(DER.expect(algorithm, Tag.sequence))[0], Tag.objectIdentifier).content,
    );
    this.signature = DER.expect(signature, Tag.bitString).content.subarray(1);
    this.extensions = extensions(rest.find((node) => node.tag === 0xa3));
  }

  /** Every certificate in a PEM file, in order. */
  static fromPEM(text: string): Certificate[] {
    return pemBlocks(text, "CERTIFICATE").map((der) => new Certificate(der));
  }

  get commonName(): string | undefined {
    return this.subjectAttributes.get(OID.commonName);
  }

  get passTypeIdentifier(): string | undefined {
    const userID = this.subjectAttributes.get(OID.userID);
    return userID?.startsWith("pass.") ? userID : undefined;
  }

  get teamIdentifier(): string | undefined {
    return this.subjectAttributes.get(OID.organizationalUnitName);
  }

  get isCertificateAuthority(): boolean {
    const constraints = this.extensions.get(OID.basicConstraints);
    if (!constraints) return false;
    const first = DER.children(DER.parse(constraints.value))[0];
    return first?.tag === Tag.boolean && first.content[0] !== 0;
  }

  isIssuedBy(issuer: Certificate): boolean {
    return equal(this.issuer, issuer.subject);
  }

  isValid(at: Date): boolean {
    return this.notBefore <= at && at <= this.notAfter;
  }
}

/** Reads each RDN's first value, keyed by attribute type OID. */
function attributes(name: DER.Node): Map<string, string> {
  const result = new Map<string, string>();
  for (const rdn of DER.children(name)) {
    for (const attribute of DER.children(rdn)) {
      const [type, value] = DER.children(attribute);
      if (type?.tag !== Tag.objectIdentifier || !value) continue;
      const oid = DER.objectIdentifierString(type.content);
      const text = DER.stringValue(value);
      if (text !== undefined && !result.has(oid)) result.set(oid, text);
    }
  }
  return result;
}

function extensions(node: DER.Node | undefined): Map<string, Extension> {
  const result = new Map<string, Extension>();
  if (!node) return result;
  for (const extension of DER.children(DER.expect(DER.children(node)[0], Tag.sequence))) {
    const parts = DER.children(extension);
    const oid = DER.objectIdentifierString(DER.expect(parts[0], Tag.objectIdentifier).content);
    const critical = parts[1]?.tag === Tag.boolean && parts[1].content[0] !== 0;
    const value = DER.expect(parts[parts.length - 1], Tag.octetString).content;
    result.set(oid, { critical, value });
  }
  return result;
}
