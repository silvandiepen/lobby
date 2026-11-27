// SPDX-License-Identifier: MPL-2.0
/** The id of the server owner's own household: everything that was there before households. */
export const OWNER_HOUSEHOLD = "owner";

/** What a household row says about whether its devices may be here: in one SQL condition. */
export const HOUSEHOLD_ACTIVE = `exists (select 1 from household
  where household.id = device.household_id and household.paused_at is null
    and household.removed_at is null)`;

/** The same, and that its devices may come in from outside. */
export const HOUSEHOLD_OUTSIDE = `exists (select 1 from household
  where household.id = device.household_id and household.paused_at is null
    and household.removed_at is null and household.allow_outside = 1)`;
