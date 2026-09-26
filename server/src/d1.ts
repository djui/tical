import { fromBase64, toBase64 } from "./bytes.ts";
import type { KeyRecord, Store } from "./store.ts";

/** The parts of Cloudflare D1's API that the store uses. */
export interface D1Database {
  prepare(query: string): D1PreparedStatement;
  batch(statements: D1PreparedStatement[]): Promise<unknown[]>;
}

export interface D1PreparedStatement {
  bind(...values: unknown[]): D1PreparedStatement;
  run(): Promise<{ meta: { changes: number } }>;
  first<T>(): Promise<T | null>;
}

interface KeyRow {
  key_id: string;
  app_id: string;
  public_key: string;
  counter: number;
  environment: string;
  created_at: number;
}

/** Keeps challenges, App Attest keys, and usage counts in D1. The tables are in migrations/. */
export class D1Store implements Store {
  readonly db: D1Database;

  constructor(db: D1Database) {
    this.db = db;
  }

  async addChallenge(challenge: string, expiresAt: number): Promise<void> {
    await this.db.prepare("INSERT INTO challenges (challenge, expires_at) VALUES (?1, ?2)").bind(challenge, expiresAt).run();
  }

  async takeChallenge(challenge: string, now: number): Promise<boolean> {
    const result = await this.db
      .prepare("DELETE FROM challenges WHERE challenge = ?1 AND expires_at > ?2")
      .bind(challenge, now)
      .run();
    return result.meta.changes === 1;
  }

  async addKey(record: KeyRecord): Promise<boolean> {
    const result = await this.db
      .prepare(
        `INSERT INTO app_attest_keys (key_id, app_id, public_key, counter, environment, receipt, created_at, last_used_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
         ON CONFLICT (key_id) DO NOTHING`,
      )
      .bind(
        record.keyId,
        record.appId,
        toBase64(record.publicKey),
        record.counter,
        record.environment,
        record.receipt ? toBase64(record.receipt) : null,
        record.createdAt,
      )
      .run();
    return result.meta.changes === 1;
  }

  async key(keyId: string): Promise<KeyRecord | undefined> {
    const row = await this.db
      .prepare("SELECT key_id, app_id, public_key, counter, environment, created_at FROM app_attest_keys WHERE key_id = ?1")
      .bind(keyId)
      .first<KeyRow>();
    const publicKey = row && fromBase64(row.public_key);
    if (!row || !publicKey) return undefined;
    return {
      keyId: row.key_id,
      appId: row.app_id,
      publicKey,
      counter: row.counter,
      environment: row.environment,
      createdAt: row.created_at,
    };
  }

  async advanceCounter(keyId: string, counter: number, now: number): Promise<boolean> {
    const result = await this.db
      .prepare("UPDATE app_attest_keys SET counter = ?2, last_used_at = ?3 WHERE key_id = ?1 AND counter < ?2")
      .bind(keyId, counter, now)
      .run();
    return result.meta.changes === 1;
  }

  async consume(bucket: string, limit: number, expiresAt: number): Promise<boolean> {
    const result = await this.db
      .prepare(
        `INSERT INTO usage (bucket, uses, expires_at) VALUES (?1, 1, ?3)
         ON CONFLICT (bucket) DO UPDATE SET uses = uses + 1 WHERE uses < ?2`,
      )
      .bind(bucket, limit, expiresAt)
      .run();
    return result.meta.changes === 1;
  }

  async removeExpired(now: number, unusedSince: number): Promise<void> {
    await this.db.batch([
      this.db.prepare("DELETE FROM challenges WHERE expires_at <= ?1").bind(now),
      this.db.prepare("DELETE FROM usage WHERE expires_at <= ?1").bind(now),
      this.db.prepare("DELETE FROM app_attest_keys WHERE last_used_at < ?1").bind(unusedSince),
    ]);
  }
}
