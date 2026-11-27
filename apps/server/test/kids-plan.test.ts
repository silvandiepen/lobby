// SPDX-License-Identifier: MPL-2.0
import { describe, expect, it } from "vitest";
import {
  localDay,
  modeAt,
  nextSwitch,
  NO_PLAN,
  PlanError,
  readPlan,
  resolve,
  strictestOf,
  type Grant,
  type KidsPlan,
  type PlanContext,
} from "../src/kids/plan.ts";

const ZONE = "Europe/Amsterdam";

/** A moment by Amsterdam wall time (in winter, UTC+1; in summer, UTC+2). */
const at = (iso: string): number => {
  const wall = Date.parse(`${iso}Z`);
  // Two guesses are enough away from a change of the clock.
  for (const hours of [1, 2]) {
    const guess = wall - hours * 3_600_000;
    if (localDay(ZONE, guess) === iso.slice(0, 10)) {
      const parts = new Intl.DateTimeFormat("en-GB", {
        timeZone: ZONE,
        hour: "2-digit",
        minute: "2-digit",
        hourCycle: "h23",
      }).format(guess);
      if (parts === iso.slice(11, 16)) return guess;
    }
  }
  throw new Error(`No such moment: ${iso}`);
};

const plan = (more: Partial<KidsPlan> = {}): KidsPlan => ({
  ...NO_PLAN,
  music: true,
  blocks: [
    { days: [1, 2, 3, 4, 5], start: "08:00", end: "15:00", mode: "nothing", label: "School" },
    {
      days: [1, 2, 3, 4, 5, 6, 7],
      start: "19:30",
      end: "07:00",
      mode: "listening",
      label: "Bedtime",
    },
  ],
  ...more,
});

const context = (more: Partial<PlanContext> = {}): PlanContext => ({
  timeZone: ZONE,
  away: false,
  place: { state: "outside" },
  videoSeconds: () => 0,
  override: null,
  grants: [],
  ...more,
});

const grant = (more: Partial<Grant>): Grant => ({
  id: "g1",
  mode: "everything",
  itemId: null,
  until: Number.MAX_SAFE_INTEGER,
  by: "parent",
  at: 0,
  ...more,
});

describe("the mode at a moment", () => {
  it("follows the week, a block that goes into the next day included", () => {
    // 2026-11-24 is a Tuesday.
    expect(modeAt(plan(), context(), at("2026-11-24T10:00")).mode).toBe("nothing");
    expect(modeAt(plan(), context(), at("2026-11-24T16:00")).mode).toBe("everything");
    expect(modeAt(plan(), context(), at("2026-11-24T21:00")).mode).toBe("listening");
    // Tuesday's bedtime goes on into Wednesday morning.
    expect(modeAt(plan(), context(), at("2026-11-25T06:59")).mode).toBe("listening");
    // Wednesday 07:00 to 08:00 is free.
    expect(modeAt(plan(), context(), at("2026-11-25T07:30")).mode).toBe("everything");
    // Saturday has no school.
    expect(modeAt(plan(), context(), at("2026-11-28T10:00")).mode).toBe("everything");
    // Sunday's bedtime goes into Monday, where school then begins.
    expect(modeAt(plan(), context(), at("2026-11-30T06:00")).mode).toBe("listening");
  });

  it("says what each mode allows", () => {
    const everything = modeAt(plan(), context(), at("2026-11-24T16:00"));
    expect(everything).toMatchObject({ browse: true, video: "all", listening: true });
    const listening = modeAt(plan(), context(), at("2026-11-24T21:00"));
    expect(listening).toMatchObject({ browse: false, video: "none", listening: true });
    const nothing = modeAt(plan(), context(), at("2026-11-24T10:00"));
    expect(nothing).toMatchObject({ browse: false, video: "none", listening: false });
    // Without music there is nothing to listen to.
    const quiet = modeAt(plan({ music: false }), context(), at("2026-11-24T21:00"));
    expect(quiet.listening).toBe(false);
  });

  it("takes the strictest of overlapping blocks", () => {
    const both = plan({
      blocks: [
        { days: [2], start: "10:00", end: "12:00", mode: "listening", label: null },
        { days: [2], start: "11:00", end: "13:00", mode: "nothing", label: "Lunch" },
      ],
    });
    expect(modeAt(both, context(), at("2026-11-24T10:30")).mode).toBe("listening");
    expect(modeAt(both, context(), at("2026-11-24T11:30"))).toMatchObject({
      mode: "nothing",
      detail: "Lunch",
    });
  });

  it("lets an override win over everything while it runs", () => {
    const override = {
      mode: "everything" as const,
      until: at("2026-11-24T11:00"),
      setBy: "p",
      setAt: 0,
    };
    const sick = context({ override, away: true, place: { state: "unknown" } });
    const withRules = plan({ away: "nothing", places: [place("school", "nothing")] });
    expect(modeAt(withRules, sick, at("2026-11-24T10:00"))).toMatchObject({
      mode: "everything",
      reason: "override",
    });
    // Ended: the rules again.
    expect(modeAt(withRules, sick, at("2026-11-24T11:00")).mode).toBe("nothing");
    // An override can be stricter too.
    const rest = { mode: "nothing" as const, until: at("2026-11-28T12:00"), setBy: "p", setAt: 0 };
    expect(modeAt(plan(), context({ override: rest }), at("2026-11-28T10:00")).mode).toBe(
      "nothing",
    );
  });

  it("applies the away rule and named places, failing closed", () => {
    const rules = plan({
      away: "ask",
      places: [place("school", "nothing"), place("gran", "listening")],
    });
    const sat = at("2026-11-28T10:00");
    expect(modeAt(rules, context({ away: true }), sat)).toMatchObject({
      mode: "ask",
      reason: "away",
    });
    expect(
      modeAt(rules, context({ place: { state: "inside", placeId: "gran" } }), sat),
    ).toMatchObject({ mode: "listening", reason: "place", detail: "Grandma's" });
    // Cannot tell: the strictest place.
    expect(modeAt(rules, context({ place: { state: "unknown" } }), sat)).toMatchObject({
      mode: "nothing",
      reason: "placeUnknown",
    });
    // Or what was chosen for that.
    const chosen = { ...rules, whenPlaceUnknown: "listening" as const };
    expect(modeAt(chosen, context({ place: { state: "unknown" } }), sat).mode).toBe("listening");
    // A place that is no longer in the plan is as good as not knowing.
    expect(
      modeAt(rules, context({ place: { state: "inside", placeId: "gone" } }), sat).reason,
    ).toBe("placeUnknown");
    // Without place rules, where the device is does not matter.
    expect(modeAt(plan(), context({ place: { state: "unknown" } }), sat).mode).toBe("everything");
  });

  it("ends video when the day's screen time is used", () => {
    const limited = plan({
      screenTime: { weekdayMinutes: 60, weekendMinutes: 120, whenOut: "listening" },
    });
    const used = (seconds: number): PlanContext => context({ videoSeconds: () => seconds });
    expect(modeAt(limited, used(59 * 60), at("2026-11-24T16:00")).mode).toBe("everything");
    expect(modeAt(limited, used(60 * 60), at("2026-11-24T16:00"))).toMatchObject({
      mode: "listening",
      reason: "screenTime",
    });
    // The weekend has more.
    expect(modeAt(limited, used(90 * 60), at("2026-11-28T16:00")).mode).toBe("everything");
    const strict = plan({
      screenTime: { weekdayMinutes: 60, weekendMinutes: 120, whenOut: "nothing" },
    });
    expect(modeAt(strict, used(3600), at("2026-11-24T16:00")).mode).toBe("nothing");
  });

  it("is stricter with Only listening than with Ask first, and asks nothing then", () => {
    const rules = plan({ away: "ask" });
    const evening = modeAt(rules, context({ away: true }), at("2026-11-24T21:00"));
    expect(evening).toMatchObject({ mode: "listening", waiting: false, listening: true });
  });
});

describe("answers to Ask first", () => {
  const asking = plan({ defaultMode: "ask", blocks: [] });
  const sat = at("2026-11-28T16:00");

  it("asks to open: nothing until an answer, then what was answered", () => {
    expect(modeAt(asking, context(), sat)).toMatchObject({
      mode: "ask",
      waiting: true,
      browse: false,
      listening: false,
      video: "none",
    });
    const watch = context({ grants: [grant({ until: sat + 3_600_000 })] });
    expect(modeAt(asking, watch, sat)).toMatchObject({
      waiting: false,
      browse: true,
      video: "all",
    });
    const listen = context({ grants: [grant({ mode: "listening", until: sat + 3_600_000 })] });
    expect(modeAt(asking, listen, sat)).toMatchObject({
      browse: false,
      video: "none",
      listening: true,
    });
    // An answer that ended is no answer.
    const ended = context({ grants: [grant({ until: sat })] });
    expect(modeAt(asking, ended, sat).waiting).toBe(true);
    // The latest answer counts: switched from Watch to Listen.
    const switched = context({
      grants: [
        grant({ id: "a", at: 1, until: sat + 3_600_000 }),
        grant({ id: "b", at: 2, mode: "listening", until: sat + 3_600_000 }),
      ],
    });
    expect(modeAt(asking, switched, sat)).toMatchObject({ video: "none", grantId: "b" });
  });

  it("asks per title: looking and listening free, video only for what was allowed", () => {
    const perTitle = { ...asking, askStyle: "title" as const };
    expect(modeAt(perTitle, context(), sat)).toMatchObject({
      browse: true,
      video: "none",
      listening: true,
      waiting: false,
    });
    const frozen = context({ grants: [grant({ itemId: "frozen", until: sat + 3_600_000 })] });
    expect(modeAt(perTitle, frozen, sat)).toMatchObject({ video: "titles", titles: ["frozen"] });
    const hour = context({ grants: [grant({ until: sat + 3_600_000 })] });
    expect(modeAt(perTitle, hour, sat).video).toBe("all");
  });

  it("never lifts a stricter mode: an answer ends at bedtime", () => {
    const evening = plan({ defaultMode: "ask" });
    const seven = at("2026-11-24T19:00");
    const twoHours = context({ grants: [grant({ until: seven + 2 * 3_600_000 })] });
    const now = resolve(evening, twoHours, seven);
    expect(now).toMatchObject({ video: "all" });
    expect(now.until).toBe(at("2026-11-24T19:30"));
    expect(now.next).toMatchObject({ mode: "listening", video: "none" });
  });
});

describe("until when", () => {
  it("finds the next switch, skipping blocks that change nothing", () => {
    const now = resolve(plan(), context(), at("2026-11-24T16:00"));
    expect(now.until).toBe(at("2026-11-24T19:30"));
    expect(now.next?.mode).toBe("listening");
    // Friday evening: bedtime, then a free Saturday morning.
    const friday = resolve(plan(), context(), at("2026-11-27T20:00"));
    expect(friday.until).toBe(at("2026-11-28T07:00"));
  });

  it("knows the end of an override and of an answer", () => {
    const until = at("2026-11-28T12:00");
    const rest = { mode: "nothing" as const, until, setBy: "p", setAt: 0 };
    expect(resolve(plan(), context({ override: rest }), at("2026-11-28T10:00")).until).toBe(until);
    // "Until the next switch" leaves the override out.
    expect(nextSwitch(plan(), context({ override: rest }), at("2026-11-28T10:00"))).toBe(
      at("2026-11-28T19:30"),
    );
  });

  it("is none for a plan that never changes", () => {
    expect(resolve(NO_PLAN, context(), at("2026-11-24T10:00")).until).toBeNull();
  });

  it("starts the next day's screen time again at midnight", () => {
    const limited = plan({
      blocks: [],
      screenTime: { weekdayMinutes: 60, weekendMinutes: 60, whenOut: "nothing" },
    });
    const now = resolve(limited, context({ videoSeconds: () => 3600 }), at("2026-11-24T16:00"));
    expect(now.mode).toBe("nothing");
    expect(now.until).toBe(at("2026-11-25T00:00"));
    expect(now.screenTime).toEqual({ day: "2026-11-24", limitMinutes: 60, usedSeconds: 3600 });
  });
});

describe("summer time", () => {
  // Amsterdam: 2026-03-29 02:00 becomes 03:00; 2026-10-25 03:00 becomes 02:00.
  const earlyBird = plan({
    blocks: [{ days: [7], start: "02:30", end: "04:00", mode: "nothing", label: null }],
  });

  it("starts a block in the hour that does not exist when that hour ends", () => {
    const before = Date.parse("2026-03-29T00:30:00Z"); // 01:30 local, winter time
    const now = resolve(earlyBird, context(), before);
    // 01:00 UTC is when 02:00 becomes 03:00: from then the local time is past 02:30.
    expect(now.until).toBe(Date.parse("2026-03-29T01:00:00Z"));
    expect(modeAt(earlyBird, context(), Date.parse("2026-03-29T01:30:00Z")).mode).toBe("nothing");
    // And ends at 04:00 summer time.
    expect(resolve(earlyBird, context(), Date.parse("2026-03-29T01:30:00Z")).until).toBe(
      Date.parse("2026-03-29T02:00:00Z"),
    );
  });

  it("goes by the clock on the wall in the hour that is there twice", () => {
    // 02:30 summer time on 2026-10-25 is 00:30 UTC; the block starts then.
    const start = resolve(earlyBird, context(), Date.parse("2026-10-25T00:00:00Z"));
    expect(start.until).toBe(Date.parse("2026-10-25T00:30:00Z"));
    // At 03:00 summer time the clock goes back to 02:00: before 02:30 again, so the block
    // pauses for half an hour, as a wall clock says, and holds until 04:00 winter time.
    const during = resolve(earlyBird, context(), Date.parse("2026-10-25T00:30:00Z"));
    expect(during.mode).toBe("nothing");
    expect(during.until).toBe(Date.parse("2026-10-25T01:00:00Z"));
    const again = resolve(earlyBird, context(), Date.parse("2026-10-25T01:30:00Z"));
    expect(again.mode).toBe("nothing");
    expect(again.until).toBe(Date.parse("2026-10-25T03:00:00Z"));
  });

  it("keeps an evening block at the same local time on both sides", () => {
    const bedtime = plan({ blocks: plan().blocks.slice(1) });
    // Saturday before the change: 19:30 summer time is 17:30 UTC.
    expect(resolve(bedtime, context(), Date.parse("2026-10-24T12:00:00Z")).until).toBe(
      Date.parse("2026-10-24T17:30:00Z"),
    );
    // Sunday after it: 19:30 winter time is 18:30 UTC.
    expect(resolve(bedtime, context(), Date.parse("2026-10-25T12:00:00Z")).until).toBe(
      Date.parse("2026-10-25T18:30:00Z"),
    );
  });
});

describe("reading a plan", () => {
  it("reads a whole plan and fills in what is left out", () => {
    expect(readPlan({})).toEqual(NO_PLAN);
    const read = readPlan({
      defaultMode: "everything",
      blocks: [{ days: [5, 1, 1], start: "08:00", end: "15:00", mode: "nothing" }],
      music: true,
      away: "ask",
      places: [place("school", "nothing")],
      screenTime: { weekdayMinutes: 60, weekendMinutes: null },
    });
    expect(read.blocks[0]).toEqual({
      days: [1, 5],
      start: "08:00",
      end: "15:00",
      mode: "nothing",
      label: null,
    });
    expect(read.screenTime).toEqual({
      weekdayMinutes: 60,
      weekendMinutes: null,
      whenOut: "listening",
    });
  });

  it("takes places up to ten kilometres, and the grown-ups who are asked", () => {
    const read = readPlan({
      places: [{ ...place("far", "nothing"), radiusMeters: 10_000 }],
      askers: [
        { profileId: "mum", deviceIds: ["phone", "mac"] },
        { profileId: "dad", deviceIds: ["phone2", "phone"] },
      ],
    });
    expect(read.places[0]?.radiusMeters).toBe(10_000);
    expect(read.askDevices).toEqual(["phone", "mac", "phone2"]);
    expect(read.musicSourceIds).toBeNull();
    expect(read.music).toBe(true);
    expect(() =>
      readPlan({ places: [{ ...place("far", "nothing"), radiusMeters: 10_001 }] }),
    ).toThrow(PlanError);
  });

  it("refuses what makes no sense", () => {
    for (const bad of [
      { defaultMode: "sometimes" },
      { blocks: [{ days: [8], start: "08:00", end: "09:00", mode: "nothing" }] },
      { blocks: [{ days: [1], start: "8:00", end: "09:00", mode: "nothing" }] },
      { blocks: [{ days: [1], start: "09:00", end: "09:00", mode: "nothing" }] },
      { places: [{ ...place("a", "nothing"), radiusMeters: 50 }] },
      { places: [{ ...place("a", "nothing"), latitude: 91 }] },
      { places: [place("a", "nothing"), place("a", "nothing")] },
      { screenTime: { weekdayMinutes: -1 } },
      { music: "yes" },
    ]) {
      expect(() => readPlan(bad), JSON.stringify(bad)).toThrow(PlanError);
    }
  });

  it("knows the strictest mode a plan names", () => {
    expect(strictestOf(NO_PLAN)).toBe("everything");
    expect(strictestOf(plan())).toBe("nothing");
    expect(strictestOf(plan({ blocks: [], away: "listening" }))).toBe("listening");
  });
});

function place(id: string, mode: KidsPlan["defaultMode"]) {
  return {
    id,
    name: id === "gran" ? "Grandma's" : "School",
    latitude: 52.37,
    longitude: 4.89,
    radiusMeters: 300,
    mode,
  };
}
