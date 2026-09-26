/** What the service remembers between requests. Times are seconds since 1970. */
import type { Bytes } from "./bytes.ts";

export interface KeyRecord {
  /** Base64, as the app sends it. */
  keyId: string;
  appId: string;
  /** The key's SubjectPublicKeyInfo. */
  publicKey: Bytes;
  counter: number;
  environment: string;
  receipt?: Bytes;
  createdAt: number;
}

export interface Store {
  addChallenge(challenge: string, expiresAt: number): Promise<void>;
  /** Removes the challenge, and reports whether it existed and hadn't expired. */
  takeChallenge(challenge: string, now: number): Promise<boolean>;
  /** Returns false when the key was already registered. */
  addKey(record: KeyRecord): Promise<boolean>;
  key(keyId: string): Promise<KeyRecord | undefined>;
  /** Raises the key's counter, and returns false unless the new counter is higher. */
  advanceCounter(keyId: string, counter: number, now: number): Promise<boolean>;
  /** Counts one use of `bucket`, and returns false once it has been used `limit` times. */
  consume(bucket: string, limit: number, expiresAt: number): Promise<boolean>;
  /** Forgets expired challenges and counts, and keys unused since `unusedSince`. */
  removeExpired(now: number, unusedSince: number): Promise<void>;
}

/** A store for tests. */
export class MemoryStore implements Store {
  readonly challenges = new Map<string, number>();
  readonly keys = new Map<string, KeyRecord & { lastUsedAt: number }>();
  readonly usage = new Map<string, { uses: number; expiresAt: number }>();

  async addChallenge(challenge: string, expiresAt: number): Promise<void> {
    this.challenges.set(challenge, expiresAt);
  }

  async takeChallenge(challenge: string, now: number): Promise<boolean> {
    const expiresAt = this.challenges.get(challenge);
    this.challenges.delete(challenge);
    return expiresAt !== undefined && expiresAt > now;
  }

  async addKey(record: KeyRecord): Promise<boolean> {
    if (this.keys.has(record.keyId)) return false;
    this.keys.set(record.keyId, { ...record, lastUsedAt: record.createdAt });
    return true;
  }

  async key(keyId: string): Promise<KeyRecord | undefined> {
    const stored = this.keys.get(keyId);
    if (!stored) return undefined;
    const { lastUsedAt: _, ...record } = stored;
    return record;
  }

  async advanceCounter(keyId: string, counter: number, now: number): Promise<boolean> {
    const stored = this.keys.get(keyId);
    if (!stored || stored.counter >= counter) return false;
    stored.counter = counter;
    stored.lastUsedAt = now;
    return true;
  }

  async consume(bucket: string, limit: number, expiresAt: number): Promise<boolean> {
    const entry = this.usage.get(bucket) ?? { uses: 0, expiresAt };
    if (entry.uses >= limit) return false;
    entry.uses += 1;
    this.usage.set(bucket, entry);
    return true;
  }

  async removeExpired(now: number, unusedSince: number): Promise<void> {
    for (const [challenge, expiresAt] of this.challenges) if (expiresAt <= now) this.challenges.delete(challenge);
    for (const [bucket, entry] of this.usage) if (entry.expiresAt <= now) this.usage.delete(bucket);
    for (const [keyId, record] of this.keys) if (record.lastUsedAt < unusedSince) this.keys.delete(keyId);
  }
}
