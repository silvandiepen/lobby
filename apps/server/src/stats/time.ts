// SPDX-License-Identifier: MPL-2.0
const HOUR_MS = 3_600_000;
export const DAY_MS = 24 * HOUR_MS;

/** Where in a viewer's week a moment falls. Monday is 0. */
export interface LocalTime {
  day: string;
  month: string;
  weekday: number;
  hour: number;
}

const WEEKDAYS: Readonly<Record<string, number>> = {
  Mon: 0,
  Tue: 1,
  Wed: 2,
  Thu: 3,
  Fri: 4,
  Sat: 5,
  Sun: 6,
};

/** Whether this is a time zone the platform knows, such as "Europe/Amsterdam". */
export function isTimeZone(name: string): boolean {
  if (name.length > 64 || !/^[A-Za-z0-9_+\-/]+$/.test(name)) return false;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: name });
    return true;
  } catch {
    return false;
  }
}

/** The server's own time zone. */
export function serverTimeZone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone;
}

/**
 * Moments as a viewer in a time zone sees them. A zone changes its offset at most at whole
 * hours here and there, so each hour is worked out once.
 */
export class Clock {
  readonly timeZone: string;
  private readonly format: Intl.DateTimeFormat;
  private readonly hours = new Map<number, LocalTime & { offset: number }>();

  constructor(timeZone: string) {
    this.timeZone = timeZone;
    this.format = new Intl.DateTimeFormat("en-US", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      weekday: "short",
      hourCycle: "h23",
    });
  }

  private hourAt(at: number): LocalTime & { offset: number } {
    // Some zones are half an hour off: the quarter hour is what is looked up.
    const key = Math.floor(at / (HOUR_MS / 4));
    let known = this.hours.get(key);
    if (!known) {
      const parts: Record<string, string> = {};
      for (const part of this.format.formatToParts(new Date(key * (HOUR_MS / 4)))) {
        parts[part.type] = part.value;
      }
      const year = Number(parts["year"]);
      const month = Number(parts["month"]);
      const date = Number(parts["day"]);
      const hour = Number(parts["hour"]);
      const two = (value: number): string => String(value).padStart(2, "0");
      const start = key * (HOUR_MS / 4);
      const asUtc = Date.UTC(year, month - 1, date, hour, Number(parts["minute"]));
      known = {
        day: `${String(year)}-${two(month)}-${two(date)}`,
        month: `${String(year)}-${two(month)}`,
        weekday: WEEKDAYS[parts["weekday"] ?? ""] ?? 0,
        hour,
        offset: asUtc - start,
      };
      this.hours.set(key, known);
    }
    return known;
  }

  at(at: number): LocalTime {
    return this.hourAt(at);
  }

  /** The moment a local day begins. */
  startOf(day: string): number {
    const [year, month, date] = day.split("-").map(Number);
    const midnight = Date.UTC(year ?? 1970, (month ?? 1) - 1, date ?? 1);
    // The offset an hour or so later is the day's: a change at midnight is rare and an hour.
    const guess = midnight - this.hourAt(midnight).offset;
    return midnight - this.hourAt(guess).offset;
  }
}

/** The day after a day, on the calendar alone. */
export function nextDay(day: string): string {
  const [year, month, date] = day.split("-").map(Number);
  return new Date(Date.UTC(year ?? 1970, (month ?? 1) - 1, (date ?? 1) + 1))
    .toISOString()
    .slice(0, 10);
}

/** Every day from `first` to `last`, both included. */
export function daysBetween(first: string, last: string): string[] {
  const days: string[] = [];
  for (let day = first; day <= last && days.length < 4000; day = nextDay(day)) days.push(day);
  return days;
}

/** Every month from `first` to `last`, both included. */
export function monthsBetween(first: string, last: string): string[] {
  const months: string[] = [];
  let [year, month] = first.split("-").map(Number) as [number, number];
  for (let i = 0; i < 1200; i += 1) {
    const one = `${String(year)}-${String(month).padStart(2, "0")}`;
    if (one > last) break;
    months.push(one);
    month += 1;
    if (month > 12) {
      month = 1;
      year += 1;
    }
  }
  return months;
}

/** The day `count` days after (or before, when negative) a day, on the calendar alone. */
export function addDays(day: string, count: number): string {
  const [year, month, date] = day.split("-").map(Number);
  return new Date(Date.UTC(year ?? 1970, (month ?? 1) - 1, (date ?? 1) + count))
    .toISOString()
    .slice(0, 10);
}
