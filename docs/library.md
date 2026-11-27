# From folder to library

## Discovering media

Register each root with a stable ID and an optional hint of Movies, Series, Personal, or Mixed. Walk subdirectories on startup, watch for changes while running, and schedule reconciliation to recover missed events. Scan metadata and inspect media headers first. Avoid hashing a terabyte of unchanged files at each boot. Store job progress so a restart can continue.

A watched share can report a file long before its writer closes it. Ignore hidden and partial uploads, debounce repeated events, check size and modification time for stability, then probe the container. Retry incomplete files with backoff. Stability is a heuristic. Prefer a producer's explicit completion signal when available. If a mount disappears, mark the root unavailable and retain its catalogue.

Mac uploads write to staging on the destination volume. Verify declared size and integrity before publishing with an atomic rename. Reserve the destination name to prevent overwrites. A watcher event and a successful upload both enqueue the same idempotent indexing operation. Stage and reclaim interrupted transfers separately from completed files.

## Identification rules

1. Respect a locked manual match. Read an explicit provider ID from a filename or recognized local sidecar when available. Conflicting IDs require review.
2. Parse the filename together with its parent folders. Remove release tags such as resolution and codec from the search text. Preserve release year, edition, season number, and episode range.
3. Resolve films using title, aliases, year, and media type. Resolve a series first, then its season and episode. Use available episode title, air date, and runtime as cross-checks. Store candidate evidence for the review screen.
4. Auto-accept only strong, unambiguous matches. Otherwise show plausible candidates with years, artwork, and evidence. Permit manual search, paste of an IMDb title URL, or classification as personal media.
5. Save stable Lobby IDs and provider IDs independently. IMDb IDs may be missing. Expose Open in IMDb only for a confirmed ID. Keep the episode link distinct from the series link.

| Input | Intended catalogue result |
| --- | --- |
| Movies/The Jungle Book (1967)/movie.mkv | Folder title and year identify the film. |
| Series/Bluey/Season 02/S02E04.mkv | One show, one season, one episode. |
| Series/Example/S01E01E02.mkv | Two episode records linked to one physical file. Use explicit chapter boundaries if known. Otherwise indicate that playback starts the combined file. |
| Extras/trailer.mp4 within a film folder | A local trailer associated with its parent. |
| Holiday 2019.mp4 | A playable personal item when the owner selects that classification. |

Map specials explicitly. For conflicting DVD and broadcast order, let the manager preview and remap multiple episodes before confirming. Identify alternate editions and resolutions as variants. Never merge solely on a similar title. Match a moved file by reliable file identity or a verified fingerprint. Preserve ambiguous candidates for review and keep profile history attached to the stable item.

## Enrichment and corrections

Use TMDB for title lookup, genres, poster variants, season posters, episode stills, and video-provider references. Store its external IMDb mapping where supplied. Prefer the household language, with original-language art as fallback. Cache selected images by size on the Pi. Bundle small artwork with offline items. A metadata outage delays enrichment while local playback continues.

Prefer an explicit local trailer, then a matching official provider-hosted trailer. Store the external provider and video ID. Open supported provider playback on user request. Omit unavailable actions, including online trailers while offline. Keep local artwork, manual locks, collections, and chosen ordering through each refresh. Give the manager separate actions for changing a match and refreshing its metadata.

Provider references: [TMDB external IDs](https://developer.themoviedb.org/reference/find-by-id), [episode IDs](https://developer.themoviedb.org/reference/tv-episode-external-ids), [artwork languages](https://developer.themoviedb.org/docs/image-languages), [videos](https://developer.themoviedb.org/reference/movie-videos), [attribution and licensing](https://developer.themoviedb.org/docs/faq).
