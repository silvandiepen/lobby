// SPDX-License-Identifier: MPL-2.0
/** There is so much waiting already that one more is refused. */
export class BusyError extends Error {
  constructor() {
    super("There is too much waiting.");
  }
}

/** Runs a few at a time. The rest waits, up to a number. */
export class Gate {
  private readonly atOnce: number;
  private readonly mostWaiting: number;
  private readonly waiting: (() => void)[] = [];
  private running = 0;

  constructor(atOnce: number, mostWaiting: number) {
    this.atOnce = atOnce;
    this.mostWaiting = mostWaiting;
  }

  /** @throws BusyError when too many are waiting */
  async run<T>(work: () => Promise<T>): Promise<T> {
    if (this.running < this.atOnce) {
      this.running += 1;
    } else {
      if (this.waiting.length >= this.mostWaiting) throw new BusyError();
      // The place is handed over, so the count never goes past what is allowed.
      await new Promise<void>((go) => this.waiting.push(go));
    }
    try {
      return await work();
    } finally {
      const next = this.waiting.shift();
      if (next) next();
      else this.running -= 1;
    }
  }
}
