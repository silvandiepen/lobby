// SPDX-License-Identifier: MPL-2.0
/** How far ahead of its pace a household may be: a little, so that a player's buffer fills. */
const AHEAD_MS = 250;
/** Households that sent nothing for this long are forgotten. */
const FORGET_MS = 60_000;

/**
 * What a guest household's devices are sent, together, kept to the cap the owner set. Every
 * piece waits until the household is back on its pace: one clock per household, shared by all
 * of its streams and downloads, at home and from outside.
 */
export class Bandwidth {
  private readonly next = new Map<string, number>();
  private readonly now: () => number;

  constructor(now: () => number = Date.now) {
    this.now = now;
  }

  /** How long a piece of `bytes` has to wait before it may go. */
  take(householdId: string, bytesPerSecond: number, bytes: number): number {
    const now = this.now();
    for (const [id, at] of this.next) if (at < now - FORGET_MS) this.next.delete(id);
    const start = Math.max(now, this.next.get(householdId) ?? now);
    const end = start + (bytes / bytesPerSecond) * 1000;
    this.next.set(householdId, end);
    // A piece goes once the household's pace has come to its end, less a little ahead.
    return Math.max(0, end - now - AHEAD_MS);
  }

  /**
   * The same body, sent no faster than the cap `check` says now (null: as it comes), and cut
   * off once it says the household may have nothing any more.
   */
  limit(
    householdId: string,
    body: ReadableStream<Uint8Array>,
    check: () => { cap: number | null; active: boolean },
  ): ReadableStream<Uint8Array> {
    const reader = body.getReader();
    // Not in the same turn as a read (as kids/guard.ts): Node throws if the file stream closes
    // while it still hands over what was asked for.
    const stop = async (reason: unknown): Promise<void> => {
      await new Promise((done) => setImmediate(done));
      await reader.cancel(reason);
    };
    return new ReadableStream<Uint8Array>(
      {
        pull: async (controller) => {
          const { done, value } = await reader.read();
          if (done) {
            controller.close();
            return;
          }
          const { cap, active } = check();
          if (!active) {
            const error = new Error("This household may no longer have this.");
            controller.error(error);
            await stop(error);
            return;
          }
          if (cap !== null) {
            const wait = this.take(householdId, cap, value.byteLength);
            if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
          }
          controller.enqueue(value);
        },
        cancel: stop,
      },
      { highWaterMark: 0 },
    );
  }
}
