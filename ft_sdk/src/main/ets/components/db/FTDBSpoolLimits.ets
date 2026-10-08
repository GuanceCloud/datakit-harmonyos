/** Total capacity across active, inflight and legacy Spool files. */
export const FT_DB_SPOOL_MAX_BYTES = 8 * 1024 * 1024;

/**
 * The fallback Spool preserves a record while it fits in the total bounded
 * capacity. Native tombstones must not be truncated merely because SQLite is
 * temporarily unavailable.
 */
export const FT_DB_SPOOL_MAX_RECORD_BYTES = FT_DB_SPOOL_MAX_BYTES;

/** Maximum records decoded into one Replay DTO page. */
export const FT_DB_SPOOL_REPLAY_PAGE_RECORDS = 256;

/** Target byte budget for one Replay page; a final record may cross it. */
export const FT_DB_SPOOL_REPLAY_PAGE_BYTES = 512 * 1024;
