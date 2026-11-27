// SPDX-License-Identifier: MPL-2.0
import { mkdir, open, readdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

/** One rename on the same volume. */
export interface Move {
  from: string;
  to: string;
  /**
   * The size of the file that is moved. With it, a file is only taken for this move's
   * file when it has this size, which matters when a new file takes the very name the
   * old one had (an MP4 replaced by an MP4).
   */
  size?: number;
}

/**
 * A change to the library that must happen completely or not at all: a few
 * renames in order, then a note in the database. It is written to the drive
 * before the first rename, so whatever stops the server halfway (a crash, a
 * kill, a power cut, the drive pulled out) can be finished or taken back when
 * the server and the drive are there again.
 */
export interface Operation<Data> {
  id: string;
  kind: string;
  moves: Move[];
  /** What the note in the database needs. Kept in the journal with the moves. */
  data: Data;
}

/** Where an operation was stopped. Only tests stop one on purpose. */
export type FaultPoint = "journal" | `move:${number}` | "commit" | "recover";

export interface OperationHooks<Data> {
  /** Writes the outcome to the database. Must give the same result when run twice. */
  commit: (operation: Operation<Data>) => void | Promise<void>;
  /** The operation was taken back: nothing in the library changed. */
  abandon: (operation: Operation<Data>, reason: string) => void | Promise<void>;
  /** Called after each step is on disk. A test throws here to stand in for a crash. */
  fault?: (point: FaultPoint, operation: Operation<Data>) => void;
}

/** Thrown when files are not where any step of an operation would have left them. */
export class Inconsistent extends Error {}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
}

/** Makes a rename or a new file survive a power cut: the folder's own entry is flushed. */
export async function syncDir(path: string): Promise<void> {
  let handle;
  try {
    handle = await open(path, "r");
    await handle.sync();
  } catch (error) {
    // Some file systems cannot flush a folder; the rename itself is still atomic.
    const code = (error as NodeJS.ErrnoException).code;
    if (code !== "EINVAL" && code !== "EISDIR" && code !== "EPERM" && code !== "ENOTSUP") {
      throw error;
    }
  } finally {
    await handle?.close();
  }
}

/** Flushes a file's bytes to the drive. */
export async function syncFile(path: string): Promise<void> {
  const handle = await open(path, "r");
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

/** Writes a small file so that it is either completely there or not there. */
export async function writeDurably(path: string, text: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.tmp`;
  const handle = await open(temporary, "w");
  try {
    await handle.writeFile(text);
    await handle.sync();
  } finally {
    await handle.close();
  }
  await rename(temporary, path);
  await syncDir(dirname(path));
}

/**
 * Renames `from` to `to`, creating the folder, and refuses when something is
 * already at `to`: a rename would silently replace it. The check and the rename
 * are two steps, which is safe because nothing else writes into these folders
 * under a name Lobby chose.
 */
export async function moveWithoutReplacing(move: Move): Promise<void> {
  if (await exists(move.to)) {
    throw new Inconsistent("There is already a file where this one should go.");
  }
  await mkdir(dirname(move.to), { recursive: true });
  await rename(move.from, move.to);
  await syncDir(dirname(move.to));
  await syncDir(dirname(move.from));
}

type MoveState = "pending" | "done" | "unclear";

/** Whether this move's file is at `path`: a file of the size the move expects. */
async function holds(path: string, move: Move): Promise<boolean> {
  try {
    const info = await stat(path);
    return move.size === undefined || info.size === move.size;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
}

async function stateOf(move: Move): Promise<MoveState> {
  const [from, to] = await Promise.all([holds(move.from, move), holds(move.to, move)]);
  if (from && !to) return "pending";
  if (!from && to) return "done";
  return "unclear";
}

/**
 * Runs operations and picks up the ones that were interrupted.
 * The journal is a folder on the same drive as the files it is about.
 */
export class Journal<Data> {
  private readonly dir: string;
  private readonly hooks: OperationHooks<Data>;

  constructor(dir: string, hooks: OperationHooks<Data>) {
    this.dir = dir;
    this.hooks = hooks;
  }

  private path(id: string): string {
    return join(this.dir, `${id}.json`);
  }

  /** Runs an operation from the start. When it throws, `recover` decides what happens to it. */
  async run(operation: Operation<Data>): Promise<void> {
    await writeDurably(this.path(operation.id), JSON.stringify(operation, null, 2));
    this.hooks.fault?.("journal", operation);
    await this.finish(operation, 0);
  }

  private async finish(operation: Operation<Data>, from: number): Promise<void> {
    for (let index = from; index < operation.moves.length; index += 1) {
      const move = operation.moves[index];
      if (!move) continue;
      await moveWithoutReplacing(move);
      this.hooks.fault?.(`move:${index}`, operation);
    }
    await this.hooks.commit(operation);
    this.hooks.fault?.("commit", operation);
    await this.forget(operation.id);
  }

  private async forget(id: string): Promise<void> {
    await rm(this.path(id), { force: true });
    await syncDir(this.dir);
  }

  /**
   * Finishes or takes back every operation that was interrupted.
   *
   * Each move is judged by where the files are, not by what the journal thinks
   * happened: done (the file is at its new place), pending (still at its old), or
   * unclear. When the moves that are left can all still be made, the operation is
   * finished. When one cannot (its file is gone), the moves that were made are
   * taken back in reverse order. When anything is unclear, nothing is touched and
   * the journal stays, for a person to look at.
   *
   * @returns the operations that were left alone because they are unclear
   * @throws when the journal folder cannot be read (the drive is not connected)
   */
  async recover(): Promise<{ id: string; reason: string }[]> {
    await mkdir(this.dir, { recursive: true });
    const unclear: { id: string; reason: string }[] = [];
    for (const name of (await readdir(this.dir)).sort()) {
      const path = join(this.dir, name);
      if (name.endsWith(".tmp")) {
        // A journal entry that was never completed: its operation did not start.
        await rm(path, { force: true });
        continue;
      }
      if (!name.endsWith(".json")) continue;
      let operation: Operation<Data>;
      try {
        operation = JSON.parse(await readFile(path, "utf8")) as Operation<Data>;
      } catch {
        unclear.push({ id: name, reason: "The journal entry cannot be read." });
        continue;
      }

      this.hooks.fault?.("recover", operation);
      const states = await Promise.all(operation.moves.map(stateOf));
      const done = states.findIndex((state) => state !== "done");
      const made = done === -1 ? states.length : done;
      const rest = states.slice(made);
      if (rest.every((state) => state === "pending")) {
        try {
          await this.finish(operation, made);
        } catch (error) {
          if (!(error instanceof Inconsistent)) throw error;
          // Something else sits where a file should go. It is not ours to replace, so the
          // moves that were made are taken back: the library is as it was.
          const now = await Promise.all(operation.moves.map(stateOf));
          for (let index = operation.moves.length - 1; index >= 0; index -= 1) {
            const move = operation.moves[index];
            if (move && now[index] === "done") {
              await moveWithoutReplacing({ from: move.to, to: move.from });
            }
          }
          await this.hooks.abandon(operation, "Another file was in the way.");
          await this.forget(operation.id);
        }
        continue;
      }
      // A later move happened without an earlier one, or files are in both places or neither.
      if (rest.some((state) => state === "done") || rest[0] !== "unclear") {
        unclear.push({
          id: operation.id,
          reason: "Files are not where any step would leave them.",
        });
        continue;
      }
      // The next move cannot be made. That is only safe to take back when its file is simply gone.
      const next = operation.moves[made];
      if (!next || (await holds(next.from, next)) || (await holds(next.to, next))) {
        unclear.push({ id: operation.id, reason: "Files are in two places at once." });
        continue;
      }
      if (rest.slice(1).some((state) => state !== "pending")) {
        unclear.push({
          id: operation.id,
          reason: "Files are not where any step would leave them.",
        });
        continue;
      }
      for (let index = made - 1; index >= 0; index -= 1) {
        const move = operation.moves[index];
        if (move) await moveWithoutReplacing({ from: move.to, to: move.from });
      }
      await this.hooks.abandon(operation, "A file needed to finish was no longer there.");
      await this.forget(operation.id);
    }
    return unclear;
  }

  /** The operations waiting in the journal. */
  async pending(): Promise<string[]> {
    try {
      return (await readdir(this.dir))
        .filter((name) => name.endsWith(".json"))
        .map((name) => name.slice(0, -5));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
      throw error;
    }
  }
}

/** Writes a file beside nothing in particular; used for manifests. */
export async function writeManifest(path: string, content: unknown): Promise<void> {
  await writeFile(path, `${JSON.stringify(content, null, 2)}\n`);
  await syncFile(path);
  await syncDir(dirname(path));
}
