// SPDX-License-Identifier: MPL-2.0
import { normalizeTitle, sortTitle } from "./parse.ts";

/**
 * What a manager changed about an item. Kept apart from the automatic values and laid
 * over them when an item is read, so lookups and rescans go on underneath and putting a
 * field back needs nothing but forgetting the change.
 */
export interface Overrides {
  title?: string;
  sortTitle?: string;
  year?: number | null;
  overview?: string | null;
  genres?: string[];
  /** On a film, show or personal video; everything below it follows. */
  categoryIds?: string[];
}

export const EDITABLE_FIELDS = [
  "title",
  "sortTitle",
  "year",
  "overview",
  "genres",
  "categories",
] as const;
export type EditableField = (typeof EDITABLE_FIELDS)[number];

export function readOverrides(json: string | null): Overrides {
  return json === null ? {} : (JSON.parse(json) as Overrides);
}

/** The order title as apps sort by it. */
export function sortKey(text: string): string {
  return normalizeTitle(text) || text.trim().toLowerCase();
}

export function effectiveSortTitle(overrides: Overrides, automatic: string): string {
  if (overrides.sortTitle !== undefined) return sortKey(overrides.sortTitle);
  if (overrides.title !== undefined) return sortTitle(overrides.title) || sortKey(overrides.title);
  return automatic;
}

/** Where a field's change is kept. Categories are shown by name and kept by id. */
export function storedField(field: EditableField): keyof Overrides {
  return field === "categories" ? "categoryIds" : field;
}

export function editableFields(kind: string): EditableField[] {
  switch (kind) {
    case "movie":
    case "show":
    case "personal":
      return [...EDITABLE_FIELDS];
    case "season":
    case "episode":
      return ["title", "sortTitle", "overview"];
    default:
      return ["title", "sortTitle"];
  }
}
