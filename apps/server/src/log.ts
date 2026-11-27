// SPDX-License-Identifier: MPL-2.0
/**
 * Plain line logging to stdout, which systemd keeps bounded in the journal.
 * Never pass a credential, a token or a pairing code to it.
 */
type Fields = Record<string, string | number | boolean | null | undefined>;

/** Output that may have been cut at its beginning, without a first line that may be half a path. */
export function wholeLines(text: string): string {
  if (text.length < 4_000) return text;
  const end = text.indexOf("\n");
  return end === -1 ? "" : text.slice(end + 1);
}

/** Why ffmpeg and the system could not read a file. Says nothing about which. */
const REASON =
  /: (Invalid data found when processing input|No such file or directory|Permission denied|Input\/output error|Is a directory|No space left on device|Read-only file system|Operation not permitted)\W*$/;

/**
 * A message without the household's file names. A path has no end one can be sure of (names hold
 * spaces, quotes and colons), so the rest of its line goes, but for a reason that is known.
 */
export function withoutPaths(text: string): string {
  return text
    .split(/\r?\n/)
    .map((row) => {
      const start = /["'`]?(?:(?<![\w:/<])\/(?=[^\s/])|file:\/|(?<=:\/\/[^/\s]+)\/)/.exec(row);
      if (!start) return row;
      const reason = REASON.exec(row)?.[1];
      return `${row.slice(0, start.index)}<path>${reason === undefined ? "" : `: ${reason}`}`;
    })
    .join("\n");
}

/** Fields that carry a message from elsewhere. */
const MESSAGES = new Set(["error", "problem", "reason"]);

function line(level: string, message: string, fields?: Fields): string {
  const extra = fields
    ? Object.entries(fields)
        .filter(([, value]) => value !== undefined)
        .map(([key, value]) => [
          key,
          typeof value === "string" && MESSAGES.has(key) ? withoutPaths(value) : value,
        ])
        .map(([key, value]) => ` ${String(key)}=${JSON.stringify(value)}`)
        .join("")
    : "";
  return `${new Date().toISOString()} ${level} ${message}${extra}`;
}

export const log = {
  info(message: string, fields?: Fields): void {
    console.log(line("info", message, fields));
  },
  warn(message: string, fields?: Fields): void {
    console.warn(line("warn", message, fields));
  },
  error(message: string, fields?: Fields): void {
    console.error(line("error", message, fields));
  },
};

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
