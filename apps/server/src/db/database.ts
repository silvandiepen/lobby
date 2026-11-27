// SPDX-License-Identifier: MPL-2.0
import { backup, DatabaseSync, type SQLInputValue, type StatementSync } from "node:sqlite";
import { migrations } from "./migrations.ts";

export type Row = Record<string, SQLInputValue>;

/**
 * A thin wrapper over node:sqlite: cached statements, typed row access and
 * transactions. Everything is synchronous; queries here are short and indexed,
 * and the slow work (probing, lookups, file reads) happens outside of it.
 */
export class Database {
  private readonly db: DatabaseSync;
  private readonly statements = new Map<string, StatementSync>();
  private depth = 0;

  constructor(path: string) {
    this.db = new DatabaseSync(path);
    // First, so that every statement after it waits for another process instead of failing.
    this.db.exec("pragma busy_timeout = 10000");
    this.db.exec("pragma journal_mode = wal");
    this.db.exec("pragma synchronous = normal");
    this.db.exec("pragma foreign_keys = on");
    this.migrate();
  }

  private migrate(): void {
    this.db.exec(
      "create table if not exists schema_migration (version integer primary key, name text not null, applied_at integer not null) strict",
    );
    const applied = new Set(
      this.all<{ version: number }>("select version from schema_migration").map((r) => r.version),
    );
    for (const migration of migrations) {
      if (applied.has(migration.version)) continue;
      this.transaction(() => {
        this.db.exec(migration.sql);
        this.run("insert into schema_migration (version, name, applied_at) values (?, ?, ?)", [
          migration.version,
          migration.name,
          Date.now(),
        ]);
      });
    }
  }

  private statement(sql: string): StatementSync {
    let statement = this.statements.get(sql);
    if (!statement) {
      statement = this.db.prepare(sql);
      this.statements.set(sql, statement);
    }
    return statement;
  }

  run(sql: string, params: SQLInputValue[] = []): number {
    return Number(this.statement(sql).run(...params).changes);
  }

  get<T>(sql: string, params: SQLInputValue[] = []): T | undefined {
    return this.statement(sql).get(...params) as T | undefined;
  }

  all<T>(sql: string, params: SQLInputValue[] = []): T[] {
    return this.statement(sql).all(...params) as T[];
  }

  /** Runs `work` atomically. Nested calls join the outer transaction. */
  transaction<T>(work: () => T): T {
    if (this.depth > 0) return work();
    this.db.exec("begin immediate");
    this.depth += 1;
    try {
      const result = work();
      this.db.exec("commit");
      return result;
    } catch (error) {
      this.db.exec("rollback");
      throw error;
    } finally {
      this.depth -= 1;
    }
  }

  getMeta(key: string): string | undefined {
    return this.get<{ value: string }>("select value from meta where key = ?", [key])?.value;
  }

  setMeta(key: string, value: string): void {
    this.run(
      "insert into meta (key, value) values (?, ?) on conflict (key) do update set value = excluded.value",
      [key, value],
    );
  }

  /**
   * The library revision counts every change a client could see. Clients send
   * the last one they saw and get only what changed since.
   */
  nextRevision(): number {
    const next = this.currentRevision() + 1;
    this.setMeta("library_revision", String(next));
    return next;
  }

  currentRevision(): number {
    return Number(this.getMeta("library_revision") ?? "0");
  }

  /**
   * Writes a consistent copy of the database to `path`, safe while the server runs.
   * It copies a few pages at a time, so requests are still answered meanwhile.
   */
  async backupTo(path: string): Promise<void> {
    await backup(this.db, path, { rate: 256 });
  }

  close(): void {
    this.statements.clear();
    this.db.close();
  }
}
