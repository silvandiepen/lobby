// SPDX-License-Identifier: MPL-2.0
/**
 * Schema migrations, applied in order inside one transaction each.
 *
 * Never edit a migration that has shipped: add a new one. The catalogue on a
 * server in use upgrades in place, and its watch history has no other copy.
 */
export interface Migration {
  version: number;
  name: string;
  sql: string;
}

export const migrations: Migration[] = [
  {
    version: 1,
    name: "catalogue, devices and progress",
    sql: `
      create table meta (
        key text primary key,
        value text not null
      ) strict;

      -- A library root the household selected.
      create table source (
        id text primary key,
        path text not null unique,
        name text not null,
        hint text not null check (hint in ('movies', 'series', 'personal', 'mixed')),
        available integer not null default 1,
        last_scan_started_at integer,
        last_scan_finished_at integer,
        created_at integer not null
      ) strict;

      -- One physical media file under a source.
      create table asset (
        id text primary key,
        source_id text not null references source(id) on delete cascade,
        rel_path text not null,
        size integer not null,
        mtime_ms integer not null,
        fingerprint text,
        revision text not null,
        state text not null check (state in ('discovered', 'probed', 'failed')),
        failure text,
        attempts integer not null default 0,
        next_attempt_at integer,
        available integer not null default 1,
        missing_since integer,
        container text,
        duration_ms integer,
        bit_rate integer,
        playability text,
        playability_reason text,
        parsed_json text,
        first_seen_at integer not null,
        updated_at integer not null,
        unique (source_id, rel_path)
      ) strict;
      create index asset_state on asset (state, next_attempt_at);
      create index asset_fingerprint on asset (fingerprint);

      create table track (
        asset_id text not null references asset(id) on delete cascade,
        idx integer not null,
        kind text not null check (kind in ('video', 'audio', 'subtitle')),
        codec text not null,
        profile text,
        language text,
        title text,
        channels integer,
        width integer,
        height integer,
        pix_fmt text,
        is_default integer not null default 0,
        is_forced integer not null default 0,
        primary key (asset_id, idx)
      ) strict;

      -- A subtitle file found beside a video.
      create table sidecar (
        id text primary key,
        asset_id text not null references asset(id) on delete cascade,
        rel_path text not null,
        format text not null,
        language text,
        size integer not null,
        mtime_ms integer not null,
        unique (asset_id, rel_path)
      ) strict;

      -- Something the family sees: a film, a show, a season, an episode, an extra.
      create table item (
        id text primary key,
        kind text not null check (kind in ('movie', 'show', 'season', 'episode', 'extra', 'personal')),
        parent_id text references item(id) on delete cascade,
        ident_key text not null unique,
        title text not null,
        sort_title text not null,
        year integer,
        season_number integer,
        episode_number integer,
        overview text,
        air_date text,
        runtime_ms integer,
        match_status text not null default 'unmatched'
          check (match_status in ('unmatched', 'matched', 'needs_review', 'locked', 'personal')),
        tmdb_type text,
        tmdb_id integer,
        imdb_id text,
        metadata_json text,
        override_json text,
        candidates_json text,
        enriched_at integer,
        enrich_attempts integer not null default 0,
        enrich_next_attempt_at integer,
        added_at integer not null,
        revision integer not null
      ) strict;
      create index item_parent on item (parent_id);
      create index item_revision on item (revision);
      create index item_enrich on item (match_status, enriched_at);

      create table item_asset (
        item_id text not null references item(id) on delete cascade,
        asset_id text not null references asset(id) on delete cascade,
        role text not null default 'main' check (role in ('main', 'trailer', 'extra')),
        edition text,
        part integer,
        start_ms integer,
        end_ms integer,
        primary key (item_id, asset_id)
      ) strict;
      create index item_asset_asset on item_asset (asset_id);

      create table artwork (
        id text primary key,
        item_id text not null references item(id) on delete cascade,
        kind text not null check (kind in ('poster', 'backdrop', 'still')),
        provider text not null,
        remote_path text,
        local_path text,
        width integer,
        height integer,
        language text,
        selected integer not null default 0,
        locked integer not null default 0,
        unique (item_id, kind, provider, remote_path)
      ) strict;
      create index artwork_item on artwork (item_id, kind, selected);

      create table genre (
        id integer primary key,
        name text not null unique
      ) strict;
      create table item_genre (
        item_id text not null references item(id) on delete cascade,
        genre_id integer not null references genre(id) on delete cascade,
        primary key (item_id, genre_id)
      ) strict;

      create table collection (
        id text primary key,
        name text not null,
        created_at integer not null,
        revision integer not null
      ) strict;
      create table collection_item (
        collection_id text not null references collection(id) on delete cascade,
        item_id text not null references item(id) on delete cascade,
        position integer,
        primary key (collection_id, item_id)
      ) strict;

      -- Items removed from the catalogue, so a client's incremental refresh can drop them.
      create table tombstone (
        item_id text primary key,
        revision integer not null
      ) strict;
      create index tombstone_revision on tombstone (revision);

      create table device (
        id text primary key,
        name text not null,
        platform text not null,
        role text not null check (role in ('manager', 'viewer')),
        token_hash text not null unique,
        created_at integer not null,
        last_used_at integer,
        revoked_at integer
      ) strict;

      create table pairing_request (
        id text primary key,
        code_hash text not null,
        poll_secret_hash text not null,
        device_name text not null,
        platform text not null,
        created_at integer not null,
        expires_at integer not null,
        approved_role text,
        approved_by text references device(id),
        approved_at integer,
        completed_at integer
      ) strict;

      create table profile (
        id text primary key,
        name text not null,
        color text not null,
        created_at integer not null,
        deleted_at integer
      ) strict;

      create table progress (
        profile_id text not null references profile(id) on delete cascade,
        item_id text not null references item(id) on delete cascade,
        position_ms integer not null,
        duration_ms integer,
        completed integer not null default 0,
        revision integer not null,
        updated_at integer not null,
        primary key (profile_id, item_id)
      ) strict;
      create index progress_profile_updated on progress (profile_id, updated_at);

      -- Acknowledged progress operations, so a retried update is answered the same way twice.
      create table progress_op (
        op_id text primary key,
        profile_id text not null,
        item_id text not null,
        result_json text not null,
        created_at integer not null
      ) strict;
    `,
  },
  {
    version: 2,
    name: "editing items",
    sql: `
      -- Counts what managers changed, so two of them cannot overwrite each other unseen.
      alter table item add column edit_revision integer not null default 0;

      -- The picture Lobby would choose by itself, to go back to after a manager's choice.
      alter table artwork add column automatic integer not null default 0;
      update artwork set automatic = 1 where provider = 'tmdb' and selected = 1;
    `,
  },
  {
    version: 3,
    name: "what a manager wants on each device",
    sql: `
      -- One thing a manager put on a device: a title (film, episode, season or show),
      -- or the rule "the next N episodes this viewer has not watched of this show".
      create table device_wanted (
        id text primary key,
        device_id text not null references device(id) on delete cascade,
        kind text not null check (kind in ('item', 'next_unwatched')),
        item_id text not null references item(id) on delete cascade,
        profile_id text references profile(id) on delete cascade,
        count integer,
        position integer not null,
        added_by text,
        added_at integer not null,
        check (
          (kind = 'item' and profile_id is null and count is null) or
          (kind = 'next_unwatched' and profile_id is not null and count between 1 and 50)
        )
      ) strict;
      create unique index device_wanted_item on device_wanted (device_id, item_id) where kind = 'item';
      create unique index device_wanted_rule on device_wanted (device_id, item_id, profile_id)
        where kind = 'next_unwatched';

      -- What a device last said about one file it has or is fetching. No reference to
      -- asset: a device may still hold a file the library no longer has.
      create table device_download (
        device_id text not null references device(id) on delete cascade,
        asset_id text not null,
        revision text not null,
        state text not null check (state in ('waiting', 'downloading', 'paused', 'downloaded', 'failed')),
        bytes_done integer not null,
        bytes_total integer,
        error text,
        own integer not null default 0,
        reported_at integer not null,
        primary key (device_id, asset_id)
      ) strict;

      create table device_storage (
        device_id text primary key references device(id) on delete cascade,
        free_bytes integer,
        total_bytes integer,
        reported_at integer not null
      ) strict;

      -- A removed device loses its list at once, whoever removes it.
      create trigger device_revoked_drops_downloads
      after update of revoked_at on device
      when new.revoked_at is not null
      begin
        delete from device_wanted where device_id = new.id;
        delete from device_download where device_id = new.id;
        delete from device_storage where device_id = new.id;
      end;
    `,
  },
  {
    version: 4,
    name: "categories as settings",
    sql: `
      -- A logo's picture is kept here, not in a file, so a backup holds it.
      create table logo (
        id text primary key,
        remote_path text,
        data blob,
        width integer,
        height integer,
        transparent integer not null default 1
      ) strict;

      -- A part of the library. The one without a name is the main part.
      create table category_group (
        id text primary key,
        name text unique,
        position integer not null,
        icon text,
        color text,
        logo_id text references logo(id)
      ) strict;
      create unique index category_group_main on category_group (name is null) where name is null;

      -- Everything refers to a category by its id; the name is only shown.
      create table category (
        id text primary key,
        group_id text not null references category_group(id),
        name text not null unique,
        position integer not null,
        icon text,
        color text,
        logo_id text references logo(id)
      ) strict;

      alter table source add column category_id text references category(id) on delete set null;
      -- The config names a folder's category once, when the folder is new here.
      alter table source add column category_seeded integer not null default 0;
      create index source_category on source (category_id);
    `,
  },
  {
    version: 5,
    name: "audio library",
    sql: `
      -- A folder with music or audiobooks. Apart from "source", which holds the video folders.
      create table music_source (
        id text primary key,
        path text not null unique,
        name text not null,
        hint text not null check (hint in ('music', 'audiobooks')),
        available integer not null default 1,
        last_scan_started_at integer,
        last_scan_finished_at integer,
        created_at integer not null
      ) strict;

      -- Every audio thing an app can see, and when it last changed. One index for a sync
      -- over all kinds; a removed thing stays as its own tombstone.
      create table music_change (
        id text primary key,
        kind text not null check (kind in ('artist', 'album', 'track', 'book')),
        revision integer not null,
        removed integer not null default 0
      ) strict;
      create index music_change_revision on music_change (revision, id);

      create table music_artist (
        id text primary key,
        ident_key text not null unique,
        name text not null,
        sort_name text not null,
        mbid text,
        override_json text,
        edit_revision integer not null default 0,
        added_at integer not null
      ) strict;

      create table music_album (
        id text primary key,
        ident_key text not null unique,
        title text not null default '',
        sort_title text not null default '',
        artist_credit text not null default '',
        year integer,
        genres_json text not null default '[]',
        compilation integer not null default 0,
        mbid text,
        track_count integer not null default 0,
        disc_count integer not null default 0,
        duration_ms integer not null default 0,
        cover_id text,
        override_json text,
        edit_revision integer not null default 0,
        added_at integer not null
      ) strict;

      create table music_book (
        id text primary key,
        ident_key text not null unique,
        title text not null default '',
        sort_title text not null default '',
        authors_json text not null default '[]',
        narrators_json text not null default '[]',
        series text,
        series_position real,
        year integer,
        genres_json text not null default '[]',
        description text,
        language text,
        duration_ms integer not null default 0,
        cover_id text,
        override_json text,
        edit_revision integer not null default 0,
        added_at integer not null
      ) strict;

      -- One audio file and the track it holds. "tags_json" is what the file says; the columns
      -- are that with a manager's changes laid over it.
      create table music_track (
        id text primary key,
        source_id text not null references music_source(id) on delete cascade,
        rel_path text not null,
        dir text not null,
        album_dir text not null,
        size integer not null,
        mtime_ms integer not null,
        fingerprint text,
        sound_key text,
        revision text not null,
        state text not null check (state in ('discovered', 'probed', 'failed')),
        failure text,
        attempts integer not null default 0,
        next_attempt_at integer,
        available integer not null default 1,
        missing_since integer,
        first_seen_at integer not null,
        updated_at integer not null,

        container text,
        codec text,
        lossless integer not null default 0,
        duration_ms integer,
        bit_rate integer,
        sample_rate integer,
        bit_depth integer,
        channels integer,
        playability text,
        chapters_json text not null default '[]',
        cover_id text,
        cover_stream integer,
        tags_json text,

        album_id text references music_album(id),
        book_id text references music_book(id),
        title text not null default '',
        sort_title text not null default '',
        artist_credit text not null default '',
        disc integer,
        track integer,
        year integer,
        genres_json text not null default '[]',
        composers_json text not null default '[]',
        override_json text,
        edit_revision integer not null default 0,
        unique (source_id, rel_path)
      ) strict;
      create index music_track_state on music_track (state, next_attempt_at);
      create index music_track_fingerprint on music_track (fingerprint);
      create index music_track_sound on music_track (sound_key);
      create index music_track_album on music_track (album_id);
      create index music_track_book on music_track (book_id);
      create index music_track_cover on music_track (cover_id);
      create index music_track_album_dir on music_track (source_id, album_dir);

      -- Who made a track or an album, in order.
      create table music_credit (
        owner_id text not null,
        position integer not null,
        artist_id text not null references music_artist(id),
        primary key (owner_id, position)
      ) strict, without rowid;
      create index music_credit_artist on music_credit (artist_id);

      -- A cover picture found beside the files.
      create table music_image (
        id text primary key,
        source_id text not null references music_source(id) on delete cascade,
        rel_path text not null,
        dir text not null,
        size integer not null,
        mtime_ms integer not null,
        unique (source_id, rel_path)
      ) strict;
      create index music_image_dir on music_image (source_id, dir);

      create table music_progress (
        profile_id text not null references profile(id) on delete cascade,
        item_id text not null,
        position_ms integer not null,
        duration_ms integer,
        completed integer not null default 0,
        revision integer not null,
        updated_at integer not null,
        primary key (profile_id, item_id)
      ) strict;
      create index music_progress_revision on music_progress (profile_id, revision);
      create table music_progress_op (
        op_id text primary key,
        profile_id text not null,
        item_id text not null,
        result_json text not null,
        created_at integer not null
      ) strict;

      create table music_favourite (
        profile_id text not null references profile(id) on delete cascade,
        item_id text not null,
        kind text not null,
        favourite integer not null,
        updated_at integer not null,
        revision integer not null,
        primary key (profile_id, item_id)
      ) strict;
      create index music_favourite_revision on music_favourite (profile_id, revision);

      create table music_playlist (
        id text primary key,
        profile_id text not null references profile(id) on delete cascade,
        name text not null,
        tracks_json text not null default '[]',
        -- Counts changes to this playlist, for conflicts.
        edit_revision integer not null default 1,
        -- When it changed among everything of this viewer, for the sync.
        revision integer not null,
        created_at integer not null,
        updated_at integer not null,
        deleted_at integer
      ) strict;
      create index music_playlist_revision on music_playlist (profile_id, revision);
      -- Tracks added to a playlist, so a retry does not add them twice.
      create table music_playlist_op (
        op_id text not null,
        playlist_id text not null references music_playlist(id) on delete cascade,
        created_at integer not null,
        primary key (playlist_id, op_id)
      ) strict;

      create table music_play (
        op_id text not null,
        profile_id text not null references profile(id) on delete cascade,
        track_id text not null,
        played_at integer not null,
        played_ms integer not null,
        completed integer not null,
        primary key (profile_id, op_id)
      ) strict;
      create index music_play_time on music_play (profile_id, played_at, op_id);
      create index music_play_track on music_play (track_id);

      -- A removed viewer takes their listening along, whoever removes them.
      create trigger profile_deleted_drops_music
      after update of deleted_at on profile
      when new.deleted_at is not null
      begin
        delete from music_progress where profile_id = new.id;
        delete from music_progress_op where profile_id = new.id;
        delete from music_favourite where profile_id = new.id;
        delete from music_playlist where profile_id = new.id;
        delete from music_play where profile_id = new.id;
      end;
    `,
  },
  {
    version: 6,
    name: "converting files and replacing originals",
    sql: `
      -- One file a manager asked to convert. Kept after it is done, as the record of what happened.
      create table conversion_job (
        id text primary key,
        asset_id text not null,
        item_id text,
        source_id text not null,
        rel_path text not null,
        -- h264: old MPEG-4 video to H.264. hevc: AV1 to HEVC. repackage: MKV into MP4, nothing re-encoded.
        kind text check (kind in ('h264', 'hevc', 'repackage')),
        -- Who may do it. 'mac': too heavy for the server.
        worker text not null default 'any' check (worker in ('any', 'mac')),
        state text not null check (state in
          ('queued', 'claimed', 'converting', 'uploaded', 'verifying', 'done', 'failed', 'skipped', 'cancelled')),
        position integer not null,
        progress real not null default 0,
        reason text,
        original_size integer not null,
        original_mtime_ms integer not null,
        original_fingerprint text,
        claimed_by text,
        lease_expires_at integer,
        done_by text,
        proof_json text,
        requested_by text,
        created_at integer not null,
        updated_at integer not null
      ) strict;
      create index conversion_job_state on conversion_job (state, position);
      -- A file is in the queue once.
      create unique index conversion_job_active on conversion_job (asset_id)
        where state in ('queued', 'claimed', 'converting', 'uploaded', 'verifying');

      -- A converted file that took its original's place. The original is kept in Lobby's
      -- folder until a person says it may go.
      create table conversion_replacement (
        id text primary key,
        job_id text not null,
        asset_id text not null,
        item_id text,
        source_id text not null,
        original_rel_path text not null,
        new_rel_path text not null,
        -- Inside Lobby's folder on the drive.
        kept_path text not null,
        set_aside_path text,
        original_size integer not null,
        original_mtime_ms integer not null,
        original_fingerprint text,
        new_size integer not null,
        new_mtime_ms integer not null,
        state text not null check (state in ('replaced', 'undone', 'purged')),
        replaced_at integer not null,
        undone_at integer,
        purged_at integer
      ) strict;
      create index conversion_replacement_asset on conversion_replacement (asset_id);
    `,
  },
  {
    version: 7,
    name: "kids limits",
    sql: `
      -- What a kids viewer may see. Null: not a kids viewer.
      alter table profile add column kids_json text;
      -- The kids viewer this device belongs to. It stays when that viewer is gone: then
      -- nothing is allowed, instead of everything.
      alter table device add column kids_profile_id text references profile(id);

      -- What was last told about each title a kids viewer ever saw, so a refresh can take away
      -- what is no longer allowed. No reference to item: a removed title has to be told too.
      create table kids_item (
        profile_id text not null references profile(id) on delete cascade,
        item_id text not null,
        visible integer not null,
        -- Everything about the title that depends on the limits.
        shape text not null,
        revision integer not null,
        primary key (profile_id, item_id)
      ) strict, without rowid;
      create index kids_item_revision on kids_item (profile_id, revision);

      -- Counts every change that can move a title in or out of a limit, whoever makes it.
      insert into meta (key, value) values ('kids_epoch', '0');
      create trigger kids_item_added after insert on item
      begin
        update meta set value = cast(cast(value as integer) + 1 as text) where key = 'kids_epoch';
      end;
      create trigger kids_item_removed after delete on item
      begin
        update meta set value = cast(cast(value as integer) + 1 as text) where key = 'kids_epoch';
      end;
      create trigger kids_item_moved after update of parent_id, kind, override_json on item
      when new.parent_id is not old.parent_id or new.kind is not old.kind
        or new.override_json is not old.override_json
      begin
        update meta set value = cast(cast(value as integer) + 1 as text) where key = 'kids_epoch';
      end;
      create trigger kids_link_added after insert on item_asset
      begin
        update meta set value = cast(cast(value as integer) + 1 as text) where key = 'kids_epoch';
      end;
      create trigger kids_link_removed after delete on item_asset
      begin
        update meta set value = cast(cast(value as integer) + 1 as text) where key = 'kids_epoch';
      end;
      create trigger kids_asset_moved after update of source_id on asset
      when new.source_id is not old.source_id
      begin
        update meta set value = cast(cast(value as integer) + 1 as text) where key = 'kids_epoch';
      end;
      create trigger kids_folder_moved after update of category_id on source
      when new.category_id is not old.category_id
      begin
        update meta set value = cast(cast(value as integer) + 1 as text) where key = 'kids_epoch';
      end;
      create trigger kids_category_moved after update of group_id on category
      when new.group_id is not old.group_id
      begin
        update meta set value = cast(cast(value as integer) + 1 as text) where key = 'kids_epoch';
      end;
      create trigger kids_category_added after insert on category
      begin
        update meta set value = cast(cast(value as integer) + 1 as text) where key = 'kids_epoch';
      end;
      create trigger kids_category_removed after delete on category
      begin
        update meta set value = cast(cast(value as integer) + 1 as text) where key = 'kids_epoch';
      end;

      -- A blocked title whose files left and came back gets a new id. It stays blocked.
      create table kids_blocked_gone (
        profile_id text not null references profile(id) on delete cascade,
        ident_key text not null,
        item_id text not null,
        primary key (profile_id, ident_key)
      ) strict, without rowid;
      create trigger kids_blocked_item_removed after delete on item
      begin
        insert or replace into kids_blocked_gone (profile_id, ident_key, item_id)
          select profile.id, old.ident_key, old.id from profile
          where profile.kids_json is not null and exists (
            select 1 from json_each(profile.kids_json, '$.blockedItemIds') where value = old.id);
      end;
      create trigger kids_blocked_item_back after insert on item
      when exists (select 1 from kids_blocked_gone where ident_key = new.ident_key)
      begin
        update profile set kids_json = json_insert(kids_json, '$.blockedItemIds[#]', new.id)
          where kids_json is not null and id in (
            select profile_id from kids_blocked_gone where ident_key = new.ident_key);
        delete from kids_blocked_gone where ident_key = new.ident_key;
      end;
    `,
  },
  {
    version: 8,
    name: "outside entrance",
    sql: `
      -- Nothing that was paired before may come in from outside until a manager says so.
      alter table device add column allow_outside integer not null default 0
        check (allow_outside in (0, 1));
      alter table device add column last_outside_at integer;

      -- Who came in from outside, or tried. Requests that are alike are one row. Never holds a
      -- token, a URL or a title.
      create table outside_access (
        id integer primary key,
        at integer not null,
        until integer not null,
        count integer not null,
        device_id text,
        transport text not null,
        address text,
        route_class text not null,
        outcome text not null
      ) strict;
      create index outside_access_until on outside_access (until);
    `,
  },
  {
    version: 9,
    name: "kids blocks that outlive their files",
    sql: `
      -- By what a blocked file that went away is known when it comes back. An item made from a
      -- file gets a new id then, and so does everything in a show that was gone.
      create table kids_blocked_trace (
        profile_id text not null references profile(id) on delete cascade,
        -- The id that is in the viewer's blocked list.
        owner_id text not null,
        asset_id text not null,
        kind text not null check (kind in ('fingerprint', 'path', 'place')),
        value text not null,
        primary key (profile_id, owner_id, asset_id, kind)
      ) strict, without rowid;
      create index kids_blocked_trace_value on kids_blocked_trace (profile_id, kind, value);
    `,
  },
  {
    // Was applied after 13 on servers that had 11 to 13 already: nothing depends on it.
    version: 10,
    name: "viewer avatars",
    sql: `
      -- The id of a picture the apps carry; null: the letter.
      alter table profile add column avatar text;
    `,
  },
  {
    // 10 is another branch's. Nothing here depends on it, nor the other way around.
    version: 11,
    name: "title logos, renown and plays",
    sql: `
      -- The same table with one more kind: a check cannot be changed in place, and nothing
      -- refers to this table.
      create table artwork_next (
        id text primary key,
        item_id text not null references item(id) on delete cascade,
        kind text not null check (kind in ('poster', 'backdrop', 'still', 'logo')),
        provider text not null,
        remote_path text,
        local_path text,
        width integer,
        height integer,
        language text,
        selected integer not null default 0,
        locked integer not null default 0,
        automatic integer not null default 0,
        unique (item_id, kind, provider, remote_path)
      ) strict;
      insert into artwork_next (rowid, id, item_id, kind, provider, remote_path, local_path, width,
          height, language, selected, locked, automatic)
        select rowid, id, item_id, kind, provider, remote_path, local_path, width,
          height, language, selected, locked, automatic from artwork;
      drop table artwork;
      alter table artwork_next rename to artwork;
      create index artwork_item on artwork (item_id, kind, selected);

      alter table item add column tagline text;
      -- TMDB's numbers, as it gave them.
      alter table item add column popularity real;
      alter table item add column vote_average real;
      alter table item add column vote_count integer;
      -- When the numbers and the pictures for a banner were last fetched.
      alter table item add column facts_at integer;

      -- How much of a film or episode a viewer watched on a day. Kept for half a year.
      create table play (
        profile_id text not null references profile(id) on delete cascade,
        item_id text not null references item(id) on delete cascade,
        -- The server's local date.
        day text not null,
        watched_ms integer not null,
        -- Enough to call it watching.
        counted integer not null default 0,
        primary key (profile_id, item_id, day)
      ) strict, without rowid;
      create index play_day on play (day);
      create index play_item on play (item_id);

      -- A removed viewer takes their part along, whoever removes them.
      create trigger profile_deleted_drops_plays
      after update of deleted_at on profile
      when new.deleted_at is not null
      begin
        delete from play where profile_id = new.id;
      end;

      -- What is known from before: each viewer's last place in a title.
      insert into play (profile_id, item_id, day, watched_ms, counted)
        select progress.profile_id, progress.item_id,
          date(progress.updated_at / 1000, 'unixepoch', 'localtime'), progress.position_ms, 1
        from progress
        join item on item.id = progress.item_id and item.kind in ('movie', 'episode', 'personal')
        join profile on profile.id = progress.profile_id and profile.deleted_at is null
        where progress.position_ms >= 600000
          or (progress.duration_ms > 0 and progress.position_ms * 4 >= progress.duration_ms);

      -- Titles that jumped to the top because a file was replaced or an edition came along:
      -- nothing was added later than its oldest file was seen.
      update item set added_at = min(added_at, coalesce((
          select min(asset.first_seen_at) from item_asset
          join asset on asset.id = item_asset.asset_id
          where item_asset.item_id = item.id and item_asset.role = 'main' and asset.first_seen_at > 0),
          added_at))
        where kind in ('movie', 'episode', 'personal');
      update item set added_at = coalesce((
          select max(episode.added_at) from item as episode
          where episode.parent_id = item.id and episode.kind = 'episode'), added_at)
        where kind = 'season';
      update item set added_at = coalesce((
          select max(season.added_at) from item as season
          where season.parent_id = item.id and season.kind = 'season'), added_at)
        where kind = 'show';
    `,
  },
  {
    // 10 and 11 are on branches that were made at the same time.
    version: 12,
    name: "direct connection identities",
    sql: `
      -- What a device rings with from outside. The secret is locked with a key that is in no
      -- backup; without that key it is nothing.
      create table direct_device (
        device_id text primary key references device(id) on delete cascade,
        ring_key text not null unique,
        wrapped text not null,
        created_at integer not null
      ) strict;
      create trigger direct_device_removed after update of revoked_at on device
      when new.revoked_at is not null
      begin
        delete from direct_device where device_id = new.id;
      end;
    `,
  },
  {
    // 10 and 12 are on branches that were made at the same time.
    version: 13,
    name: "playing on another device",
    sql: `
      -- Null: what is usual for such a device, which an Apple TV and a Mac are.
      alter table device add column is_target integer check (is_target in (0, 1));
      alter table device add column allow_remote integer not null default 1
        check (allow_remote in (0, 1));
      alter table device add column remote_outside integer not null default 0
        check (remote_outside in (0, 1));
    `,
  },
  {
    // Made beside 10 to 13 on another branch; nothing here depends on them.
    version: 14,
    name: "categories inside a category",
    sql: `
      -- One level, in the same group: the rules are in library/categories.ts.
      alter table category add column parent_id text references category(id) on delete set null;
      create index category_parent on category (parent_id);
      create trigger kids_category_nested after update of parent_id on category
      when new.parent_id is not old.parent_id
      begin
        update meta set value = cast(cast(value as integer) + 1 as text) where key = 'kids_epoch';
      end;

      -- A category may also take in the titles of some studios: {"studioIds": [...]}.
      alter table category add column rule_json text;
      create trigger kids_category_rule after update of rule_json on category
      when new.rule_json is not old.rule_json
      begin
        update meta set value = cast(cast(value as integer) + 1 as text) where key = 'kids_epoch';
      end;

      -- Companies and networks as TMDB names them. "company:12", "network:34": the two count apart.
      create table studio (
        id text primary key,
        kind text not null check (kind in ('company', 'network')),
        tmdb_id integer not null,
        name text not null,
        logo_path text,
        country text,
        seen_at integer not null
      ) strict;
      create table item_studio (
        item_id text not null references item(id) on delete cascade,
        studio_id text not null references studio(id),
        position integer not null,
        primary key (item_id, studio_id)
      ) strict, without rowid;
      create index item_studio_studio on item_studio (studio_id);
      -- When a title's studios were last read; null: not yet, so the next refresh reads them.
      alter table item add column studios_at integer;
      create trigger kids_studio_added after insert on item_studio
      begin
        update meta set value = cast(cast(value as integer) + 1 as text) where key = 'kids_epoch';
      end;
      create trigger kids_studio_removed after delete on item_studio
      begin
        update meta set value = cast(cast(value as integer) + 1 as text) where key = 'kids_epoch';
      end;
      -- Studios a manager does not want suggested as a category.
      create table studio_dismissed (studio_id text primary key) strict;

      -- How the categories were before the last arrangement, for as long as nothing else changed.
      create table category_undo (
        token text primary key,
        revision integer not null,
        state_json text not null
      ) strict;
    `,
  },
  {
    // 14 is taken on branches that were made at the same time.
    version: 15,
    name: "server settings audit",
    sql: `
      -- Who changed the server's settings, or tried to, and what came of it. The values are in
      -- the settings store in the data folder; a secret is never written here.
      create table settings_audit (
        id integer primary key,
        at integer not null,
        device_id text,
        action text not null
          check (action in ('change', 'restore', 'refused', 'tmdb_set', 'tmdb_removed', 'setup')),
        version integer,
        keys_json text not null default '[]',
        note text
      ) strict;
      create index settings_audit_at on settings_audit (at);
    `,
  },
  {
    version: 16,
    name: "apple tvs to wake",
    sql: `
      -- Apple TVs Lobby Server can wake (docs/operations.md), by pyatv's id for them, and
      -- the Lobby device each is, as a manager confirmed it. The credentials are not here: they
      -- stay in pyatv's own file, which only the helper reads.
      create table wake_tv (
        id text primary key,
        name text not null,
        model text not null default '',
        device_id text references device (id) on delete set null,
        paired_at integer not null
      ) strict;
      create unique index wake_tv_device on wake_tv (device_id) where device_id is not null;
    `,
  },
  {
    version: 17,
    name: "video codec tag",
    sql: `
      -- The sample entry of a track (ffprobe's codec_tag_string): Apple devices show HEVC only
      -- as hvc1 (or dvh1), not hev1. '' when the container has none (Matroska); null for tracks
      -- read before this column, which are read again (library/video-tags.ts).
      alter table track add column codec_tag text;
    `,
  },
  {
    version: 18,
    name: "studios and ratings in items",
    sql: `
      -- Items now say who made a title and how it was rated (docs/api.md, Library). The films and
      -- shows that have either change once, so that devices fetch them again with it.
      update meta set value = cast(cast(value as integer) + 1 as text) where key = 'library_revision';
      update item set revision = (select cast(value as integer) from meta where key = 'library_revision')
      where parent_id is null and kind in ('movie', 'show', 'personal')
        and exists (select 1 from meta where key = 'library_revision')
        and (vote_count >= 10 or exists (select 1 from item_studio where item_studio.item_id = item.id));
    `,
  },
  {
    version: 19,
    name: "imports and uploads",
    sql: `
      -- A file Lobby found in an import folder or received as an upload, and what became of it
      -- (docs/imports.md). Kept after it was imported, as the record of what was moved where.
      create table import_item (
        id text primary key,
        origin text not null check (origin in ('folder', 'upload')),
        -- The import folder it is in; null for an upload.
        folder_path text,
        -- Where the file is now: in the import folder, or in Lobby's folder for an upload.
        path text not null,
        -- Below the import folder, or the name the upload was sent with.
        rel_path text not null,
        size integer not null,
        mtime_ms integer not null,
        state text not null check (state in
          ('waiting', 'inbox', 'moving', 'imported', 'listed', 'ignored', 'failed', 'dismissed')),
        reason text,
        kind text check (kind in ('movie', 'episode')),
        title text,
        year integer,
        season integer,
        episode integer,
        episode_end integer,
        episode_title text,
        tmdb_id integer,
        candidates_json text not null default '[]',
        -- A library folder chosen for it; null: the films' or the series' folder.
        destination text,
        target_path text,
        subtitles_json text not null default '[]',
        leftovers_json text not null default '[]',
        -- Files to remove once a copy to another drive was proven and is in the library.
        remove_after_json text not null default '[]',
        upload_id text,
        decided_by text,
        first_seen_at integer not null,
        stable_since integer not null,
        updated_at integer not null,
        done_at integer
      ) strict;
      create unique index import_item_path on import_item (path) where state <> 'imported';
      create index import_item_state on import_item (state, updated_at);

      create table import_activity (
        id integer primary key,
        at integer not null,
        item_id text,
        device_id text,
        action text not null,
        message text not null
      ) strict;
      create index import_activity_at on import_activity (at);

      -- An upload from a manager's device, received in pieces into Lobby's folder.
      create table upload (
        id text primary key,
        device_id text not null,
        batch text,
        rel_path text not null,
        size integer not null,
        sha256 text,
        destination_json text not null,
        state text not null check (state in ('receiving', 'verifying', 'done', 'failed', 'cancelled')),
        reason text,
        item_id text,
        created_at integer not null,
        updated_at integer not null
      ) strict;
      create index upload_state on upload (state, updated_at);
    `,
  },
  {
    version: 20,
    name: "households",
    sql: `
      -- Who shares the server (docs/decisions.md, "Households"). The owner's household is the one that
      -- was there before: everybody and every device so far is in it. A guest household gets the
      -- library as far as the owner allows, and has its own viewers, devices and managers.
      create table household (
        id text primary key,
        name text not null,
        owner integer not null default 0 check (owner in (0, 1)),
        -- What of the library it sees, as kids limits say it (allowed groups and categories);
        -- null: all of it. Never set for the owner's own household.
        scope_json text,
        -- What its devices may be sent together, in bytes a second; null: no cap.
        bandwidth integer check (bandwidth is null or bandwidth > 0),
        allow_outside integer not null default 1 check (allow_outside in (0, 1)),
        max_devices integer check (max_devices is null or max_devices > 0),
        paused_at integer,
        removed_at integer,
        created_at integer not null
      ) strict;
      create unique index household_owner on household (owner) where owner = 1;
      insert into household (id, name, owner, allow_outside, created_at)
        values ('owner', 'Home', 1, 1, cast(strftime('%s', 'now') as integer) * 1000);

      alter table device add column household_id text not null default 'owner';
      alter table profile add column household_id text not null default 'owner';
      create index device_household on device (household_id);
      create index profile_household on profile (household_id);

      -- An invitation for one device, which becomes a manager of the household. The code is not
      -- kept, only its hash, and what the direct road needs to meet the device (its room and the
      -- key stretched from the code), so that an invitation outlives a restart.
      create table household_invite (
        id text primary key,
        household_id text not null references household (id),
        code_hash blob not null,
        room text,
        room_key blob,
        created_by text not null,
        created_at integer not null,
        expires_at integer not null,
        used_at integer,
        revoked_at integer
      ) strict;
      create index household_invite_household on household_invite (household_id);

      -- What a guest household with a part of the library was told of, beside the kids viewers:
      -- those rows are kept under 'household:<id>', which is no viewer, so the reference goes.
      create table kids_item_next (
        profile_id text not null,
        item_id text not null,
        visible integer not null,
        shape text not null,
        revision integer not null,
        primary key (profile_id, item_id)
      ) strict, without rowid;
      insert into kids_item_next select profile_id, item_id, visible, shape, revision from kids_item;
      drop table kids_item;
      alter table kids_item_next rename to kids_item;
      create index kids_item_revision on kids_item (profile_id, revision);
    `,
  },
  {
    version: 21,
    name: "household admins and server approval",
    sql: `
      -- Three levels in every household (docs/decisions.md, "Server admins, household admins and viewers"): a server admin does
      -- everything, a household admin manages their own household, a viewer watches. The
      -- owner's managers are its server admins; a guest household's managers its household
      -- admins. \`role\` stays what an older server or app may read: 'manager' only for a server
      -- admin, so going back to an older server never makes a household admin more.
      alter table device add column access text not null default 'viewer'
        check (access in ('admin', 'household_admin', 'viewer'));
      update device set access = case
        when role = 'manager' and household_id = 'owner' then 'admin'
        when role = 'manager' then 'household_admin'
        else 'viewer' end;
      update device set role = 'viewer' where access != 'admin';

      -- A new device of the household needs a server admin's yes too, after its own admin's.
      -- On for the guests there are (fail closed); the owner's own household as before.
      alter table household add column requires_admin_approval integer not null default 0
        check (requires_admin_approval in (0, 1));
      update household set requires_admin_approval = 1 where owner = 0;

      -- What an invitation makes of its device: a household admin (also of a new household) or
      -- a viewer. Those from before were for a new household's first device.
      alter table household_invite add column access text not null default 'household_admin'
        check (access in ('household_admin', 'viewer'));

      -- A device at home that its household admin let in, and that waits for a server admin;
      -- or one a server admin turned away, so its admin is told.
      alter table pairing_request add column awaits_admin integer not null default 0;
      alter table pairing_request add column refused_at integer;
    `,
  },
  {
    version: 22,
    name: "subtitles per viewer",
    sql: `
      -- How a viewer wants subtitles (docs/api.md, Profiles): the languages in order, forced
      -- subtitles, size and background. Null: the defaults (off, forced on).
      alter table profile add column subtitles_json text;

      -- A subtitle file named as forced ("Film.en.forced.srt"): it carries only the lines for
      -- speech in another language. The scanner keeps this up to date from the name.
      alter table sidecar add column is_forced integer not null default 0;
      update sidecar set is_forced = 1
        where lower(rel_path) glob '*[^a-z]forced[^a-z]*';

      -- How far a viewer moved the subtitles of a title, kept for the next time.
      create table subtitle_offset (
        profile_id text not null references profile(id) on delete cascade,
        item_id text not null references item(id) on delete cascade,
        offset_ms integer not null,
        updated_at integer not null,
        primary key (profile_id, item_id)
      ) strict, without rowid;
    `,
  },
  {
    version: 23,
    name: "kids control: plans, overrides, answers and screen time",
    sql: `
      -- When and what a kids viewer may do (docs/kids-control.md). One plan per viewer;
      -- a viewer without one is as before.
      create table kids_plan (
        profile_id text primary key,
        plan_json text not null,
        updated_at integer not null,
        updated_by text
      ) strict;

      -- A grown-up's "Nothing until 15:00": one per viewer, until it ends.
      create table kids_override (
        profile_id text primary key,
        mode text not null check (mode in ('everything', 'ask', 'listening', 'nothing')),
        until integer not null,
        set_by text not null,
        set_at integer not null
      ) strict;

      -- A child asked; a grown-up answered or not. Kept for two weeks.
      create table kids_request (
        id text primary key,
        profile_id text not null,
        device_id text not null,
        kind text not null check (kind in ('open', 'title')),
        item_id text,
        state text not null check (state in ('waiting', 'allowed', 'declined', 'expired', 'cancelled')),
        created_at integer not null,
        expires_at integer not null,
        answer text check (answer in ('watch', 'listen', 'no')),
        answered_by text,
        answered_at integer,
        grant_id text
      ) strict;
      create index kids_request_profile on kids_request (profile_id, created_at);
      create index kids_request_waiting on kids_request (state, expires_at);

      -- What an answer gives, while it runs: the whole app, or one title.
      create table kids_grant (
        id text primary key,
        profile_id text not null,
        mode text not null check (mode in ('everything', 'listening')),
        item_id text,
        until integer not null,
        by text not null,
        at integer not null,
        request_id text
      ) strict;
      create index kids_grant_profile on kids_grant (profile_id, until);

      -- Seconds of video per viewer and local day.
      create table kids_screen_time (
        profile_id text not null,
        day text not null,
        seconds integer not null,
        primary key (profile_id, day)
      ) strict, without rowid;

      -- The household's own clock for its plans; null: the server's.
      alter table household add column time_zone text;
    `,
  },
  {
    version: 24,
    name: "statistics",
    sql: `
      -- One sitting with a film or an episode (docs/decisions.md, "Statistics"): who, on which device,
      -- from where, how it was sent, and how much of it was really watched. Worked out from the
      -- places the apps report; kept for as long as the household says (statistics.keepDays).
      create table watch_session (
        id text primary key,
        profile_id text not null references profile(id) on delete cascade,
        -- The viewer's household when it was watched.
        household_id text not null,
        -- The device that played it. Null for what is known from before.
        device_id text,
        item_id text not null,
        -- The film, or the series an episode is of.
        title_id text not null,
        started_at integer not null,
        ended_at integer not null,
        -- 0: only the day is known (from before), not the hour.
        timed integer not null default 1 check (timed in (0, 1)),
        watched_ms integer not null,
        position_ms integer not null default 0,
        duration_ms integer,
        -- Finished in this sitting.
        completed integer not null default 0 check (completed in (0, 1)),
        road text not null default 'unknown'
          check (road in ('home', 'tailnet', 'relay', 'direct', 'unknown')),
        delivery text not null default 'unknown'
          check (delivery in ('direct', 'prepared', 'download', 'unknown')),
        -- The device that sent it here with Play On.
        play_on_from text
      ) strict;
      create index watch_session_profile on watch_session (profile_id, started_at);
      create index watch_session_time on watch_session (started_at);
      create index watch_session_open on watch_session (profile_id, item_id, ended_at);

      -- Bytes of films and music sent, per hour (since the epoch), household and road.
      create table stats_traffic (
        hour integer not null,
        household_id text not null,
        road text not null,
        bytes integer not null,
        primary key (hour, household_id, road)
      ) strict, without rowid;

      -- What the server did: copies it prepared for playback, files it converted.
      create table stats_event (
        id integer primary key,
        kind text not null check (kind in ('prepared', 'conversion_claimed', 'converted')),
        at integer not null,
        asset_id text,
        job_id text,
        elapsed_ms integer,
        bytes integer,
        saved_bytes integer,
        converted integer not null default 0,
        background integer not null default 0
      ) strict;
      create index stats_event_time on stats_event (kind, at);
      create index stats_event_job on stats_event (job_id) where job_id is not null;

      -- Listening across the server, by time.
      create index music_play_at on music_play (played_at);

      -- A removed viewer takes their sittings along, whoever removes them.
      create trigger profile_deleted_drops_sessions
      after update of deleted_at on profile
      when new.deleted_at is not null
      begin
        delete from watch_session where profile_id = new.id;
      end;

      -- What is known from before: a sitting a day, at noon of the server's day, untimed.
      insert into watch_session (id, profile_id, household_id, device_id, item_id, title_id,
          started_at, ended_at, timed, watched_ms, position_ms, duration_ms, completed)
        select 'before:' || play.profile_id || ':' || play.item_id || ':' || play.day,
          play.profile_id, profile.household_id, null, play.item_id,
          coalesce(above.parent_id, item.parent_id, item.id),
          cast(strftime('%s', play.day || ' 12:00:00', 'utc') as integer) * 1000,
          cast(strftime('%s', play.day || ' 12:00:00', 'utc') as integer) * 1000 + play.watched_ms,
          0, play.watched_ms, coalesce(progress.position_ms, 0), progress.duration_ms,
          coalesce(progress.completed = 1
            and date(progress.updated_at / 1000, 'unixepoch', 'localtime') = play.day, 0)
        from play
        join item on item.id = play.item_id
        join profile on profile.id = play.profile_id and profile.deleted_at is null
        left join item as above on above.id = item.parent_id and item.kind = 'episode'
        left join progress on progress.profile_id = play.profile_id
          and progress.item_id = play.item_id
        where play.watched_ms > 0;
    `,
  },
  {
    version: 25,
    name: "what happens at the end, per viewer",
    sql: `
      -- What happens when something ends (docs/api.md, Profiles): suggestions after a film, the
      -- next episode by itself, "Still watching?". Only what the viewer chose; null: the
      -- defaults of their kind.
      alter table profile add column playback_json text;
    `,
  },
  {
    version: 26,
    name: "search",
    sql: `
      -- Who made and played in a film or show, as TMDB says (docs/api.md, Search). Read with
      -- the title's details; what was matched before gets them in the refreshes, a few a run.
      create table person (
        id integer primary key,
        name text not null,
        profile_path text,
        seen_at integer not null
      ) strict;
      create table item_credit (
        item_id text not null references item(id) on delete cascade,
        person_id integer not null references person(id),
        role text not null check (role in ('cast', 'director', 'writer', 'creator')),
        character text,
        position integer not null,
        primary key (item_id, person_id, role)
      ) strict, without rowid;
      create index item_credit_person on item_credit (person_id);
      -- Other names a title is known by (TMDB's alternative titles and translations).
      create table item_alias (
        item_id text not null references item(id) on delete cascade,
        title text not null,
        primary key (item_id, title)
      ) strict, without rowid;
      -- A film's collection ("Toy Story Collection").
      alter table item add column collection_id integer;
      alter table item add column collection_name text;
      -- When the credits were last read; null: not yet.
      alter table item add column credits_at integer;

      -- Ratings from OMDb (IMDb, Rotten Tomatoes, Metacritic), only when the owner set an OMDb
      -- key. Per IMDb id, looked at again after a while. Null: OMDb does not have that one.
      create table omdb_rating (
        imdb_id text primary key,
        imdb_rating real,
        imdb_votes integer,
        rotten_tomatoes integer,
        metacritic integer,
        found integer not null,
        fetched_at integer not null
      ) strict;

      -- The search index: one row per film, show, video and episode. Words, prefixes and
      -- letters without their accents ("amelie" finds "Amélie").
      create virtual table search_text using fts5(
        item_id unindexed,
        title, aliases, people, characters, studios, genres, collection, overview,
        tokenize = 'unicode61 remove_diacritics 2',
        prefix = '2 3'
      );
      -- What the words of the index are, for a word that was typed wrong.
      create virtual table search_words using fts5vocab(search_text, 'row');
      -- Parts of words ("atrix" finds "The Matrix"), titles and names only.
      create virtual table search_parts using fts5(
        item_id unindexed,
        text,
        tokenize = 'trigram remove_diacritics 1'
      );
      -- Names of people, by the same rules.
      create virtual table person_text using fts5(
        person_id unindexed,
        name,
        tokenize = 'unicode61 remove_diacritics 2',
        prefix = '2 3'
      );
      -- Titles whose words changed apart from the library revision (credits, aliases).
      create table search_dirty (item_id text primary key) strict, without rowid;

      -- The audit log says when the owner set or removed the OMDb key, too.
      create table settings_audit_next (
        id integer primary key,
        at integer not null,
        device_id text,
        action text not null
          check (action in ('change', 'restore', 'refused', 'tmdb_set', 'tmdb_removed', 'setup',
            'omdb_set', 'omdb_removed')),
        version integer,
        keys_json text not null default '[]',
        note text
      ) strict;
      insert into settings_audit_next select id, at, device_id, action, version, keys_json, note
        from settings_audit;
      drop table settings_audit;
      alter table settings_audit_next rename to settings_audit;
      create index settings_audit_at on settings_audit (at);
    `,
  },
  {
    version: 27,
    name: "intro and credits markers",
    sql: `
      -- Where a file's intro and credits are (docs/decisions.md, "Skip Intro"), from each of three
      -- sources: a manager by hand, the file's chapters, or found by comparing the sound of the
      -- episodes of a season. Manual wins over chapters, chapters over detected. A manual row
      -- with no times says there is none. Chapters and detected rows hold for the file's
      -- revision they were read from; a manual one for the file, also after converting.
      create table marker (
        asset_id text not null references asset(id) on delete cascade,
        kind text not null check (kind in ('intro', 'credits')),
        source text not null check (source in ('manual', 'chapters', 'detected')),
        start_ms integer check (start_ms is null or start_ms >= 0),
        end_ms integer check (end_ms is null or end_ms > start_ms),
        confidence real not null default 1,
        detector integer,
        asset_revision text,
        updated_at integer not null,
        primary key (asset_id, kind, source)
      ) strict, without rowid;

      -- How far the background job got with a file, so it goes on where it stopped. The
      -- fingerprints themselves are files in the cache.
      create table marker_scan (
        asset_id text primary key references asset(id) on delete cascade,
        revision text not null,
        detector integer not null,
        chapters_at integer,
        printed_at integer,
        matched_at integer,
        -- A manager asked for this one: it goes first, at any hour.
        requested_at integer,
        failures integer not null default 0,
        reason text,
        updated_at integer not null
      ) strict;
      create index marker_scan_requested on marker_scan (requested_at);

      -- A season's theme once it is known: a stretch of one episode's fingerprint, against which
      -- a new episode is matched alone instead of against its neighbours.
      create table season_theme (
        season_id text not null references item(id) on delete cascade,
        kind text not null check (kind in ('intro', 'credits')),
        asset_id text not null references asset(id) on delete cascade,
        asset_revision text not null,
        start_ms integer not null,
        end_ms integer not null,
        detector integer not null,
        updated_at integer not null,
        primary key (season_id, kind)
      ) strict, without rowid;

      -- How a viewer wants intros and credits (docs/api.md, Profiles). Null: the defaults.
      alter table profile add column skipping_json text;
    `,
  },
  {
    version: 28,
    name: "push tokens",
    sql: `
      -- Where Apple's push service reaches a device: one token per device, replaced when the
      -- app says another. Gone with the device (docs/operations.md, Push notifications).
      create table push_token (
        device_id text primary key,
        token text not null,
        environment text not null check (environment in ('development', 'production')),
        updated_at integer not null
      ) strict;
    `,
  },
  {
    version: 29,
    name: "push through the relay",
    sql: `
      -- Where the push relay reaches a device (docs/decisions.md, "Push through a relay"): the
      -- handle the relay gave the app for this server's box, never the device token, and the key
      -- the app made for what this server seals for it. One per device, replaced when the app says
      -- another. Gone with the device.
      create table push_relay (
        device_id text primary key,
        handle text not null,
        key text not null,
        environment text not null check (environment in ('development', 'production')),
        updated_at integer not null
      ) strict;
    `,
  },
];
