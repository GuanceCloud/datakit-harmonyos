/**
 * HarmonyOS SDK database SQL statement definition class
 */

/**
 * Sync data table name (new version)
 */
export const FT_SYNC_DATA_FLAT_TABLE_NAME: string = "sync_data_flat";

/**
 * RUM view table name
 */
export const FT_TABLE_VIEW: string = "rum_view";

/**
 * RUM action table name
 */
export const FT_TABLE_ACTION: string = "rum_action";

/**
 * Record column definitions
 */
export const RECORD_COLUMN_ID: string = "_id";
export const RECORD_COLUMN_TM: string = "tm";
export const RECORD_COLUMN_DATA_UUID: string = "uuid";
export const RECORD_COLUMN_DATA: string = "data";
export const RECORD_COLUMN_DATA_TYPE: string = "type";

/**
 * RUM column definitions
 */
export const RUM_COLUMN_ID: string = "id";
export const RUM_COLUMN_START_TIME: string = "start_time";
export const RUM_COLUMN_IS_CLOSE: string = "is_close";
export const RUM_COLUMN_ERROR_COUNT: string = "error_count";
export const RUM_COLUMN_LONG_TASK_COUNT: string = "long_task_count";
export const RUM_COLUMN_RESOURCE_COUNT: string = "resource_count";
export const RUM_COLUMN_PENDING_RESOURCE: string = "pending_resource";
export const RUM_COLUMN_SESSION_ID: string = "session_id";
export const RUM_COLUMN_VIEW_NAME: string = "view_name";
export const RUM_COLUMN_VIEW_ID: string = "view_id";
export const RUM_COLUMN_VIEW_REFERRER: string = "view_referrer";
export const RUM_COLUMN_ACTION_COUNT: string = "action_count";
export const RUM_COLUMN_VIEW_LOAD_TIME: string = "view_load_time";
export const RUM_COLUMN_VIEW_TIME_SPENT: string = "view_time_spent";
export const RUM_COLUMN_ACTION_NAME: string = "action_name";
export const RUM_COLUMN_ACTION_TYPE: string = "action_type";
export const RUM_COLUMN_ACTION_DURATION: string = "action_duration";
export const RUM_COLUMN_EXTRA_ATTR: string = "extra_attr";
export const RUM_DATA_UPDATE_TIME: string = "data_update_time";
export const RUM_DATA_UPLOAD_TIME: string = "data_upload_time";
export const RUM_VIEW_UPDATE_TIME: string = "view_update_time";

/**
 * Sync data table creation SQL
 */
export const FT_TABLE_SYNC_CREATE: string = 
  `CREATE TABLE IF NOT EXISTS ${FT_SYNC_DATA_FLAT_TABLE_NAME} (
    ${RECORD_COLUMN_ID} INTEGER PRIMARY KEY AUTOINCREMENT,
    ${RECORD_COLUMN_TM} BIGINT,
    ${RECORD_COLUMN_DATA_UUID} TEXT,
    ${RECORD_COLUMN_DATA} TEXT,
    ${RECORD_COLUMN_DATA_TYPE} TEXT
  )`;

/**
 * RUM view table creation SQL
 */
export const FT_TABLE_VIEW_CREATE: string = 
  `CREATE TABLE IF NOT EXISTS ${FT_TABLE_VIEW} (
    ${RUM_COLUMN_ID} TEXT PRIMARY KEY,
    ${RUM_COLUMN_VIEW_NAME} TEXT,
    ${RUM_COLUMN_VIEW_REFERRER} TEXT,
    ${RUM_COLUMN_START_TIME} BIGINT,
    ${RUM_COLUMN_IS_CLOSE} INTEGER,
    ${RUM_COLUMN_SESSION_ID} TEXT,
    ${RUM_COLUMN_ACTION_COUNT} INTEGER,
    ${RUM_COLUMN_ERROR_COUNT} INTEGER,
    ${RUM_COLUMN_LONG_TASK_COUNT} INTEGER,
    ${RUM_COLUMN_VIEW_LOAD_TIME} BIGINT,
    ${RUM_COLUMN_VIEW_TIME_SPENT} BIGINT,
    ${RUM_COLUMN_RESOURCE_COUNT} INTEGER,
    ${RUM_COLUMN_PENDING_RESOURCE} INTEGER,
    ${RUM_DATA_UPDATE_TIME} BIGINT DEFAULT 0,
    ${RUM_DATA_UPLOAD_TIME} BIGINT DEFAULT 0,
    ${RUM_VIEW_UPDATE_TIME} BIGINT DEFAULT 1,
    ${RUM_COLUMN_EXTRA_ATTR} TEXT
  )`;

/**
 * RUM action table creation SQL
 */
export const FT_TABLE_ACTION_CREATE: string = 
  `CREATE TABLE IF NOT EXISTS ${FT_TABLE_ACTION} (
    ${RUM_COLUMN_ID} TEXT PRIMARY KEY,
    ${RUM_COLUMN_START_TIME} BIGINT,
    ${RUM_COLUMN_ACTION_DURATION} BIGINT,
    ${RUM_COLUMN_IS_CLOSE} INTEGER,
    ${RUM_COLUMN_ERROR_COUNT} INTEGER,
    ${RUM_COLUMN_LONG_TASK_COUNT} INTEGER,
    ${RUM_COLUMN_RESOURCE_COUNT} INTEGER,
    ${RUM_COLUMN_PENDING_RESOURCE} INTEGER,
    ${RUM_COLUMN_SESSION_ID} TEXT,
    ${RUM_COLUMN_VIEW_NAME} TEXT,
    ${RUM_COLUMN_VIEW_ID} TEXT,
    ${RUM_COLUMN_VIEW_REFERRER} TEXT,
    ${RUM_COLUMN_ACTION_NAME} TEXT,
    ${RUM_COLUMN_ACTION_TYPE} TEXT,
    ${RUM_COLUMN_EXTRA_ATTR} TEXT
  )`;

/**
 * SQL used to create database indexes
 */
export const CREATE_INDEXES: string[] = [
  `CREATE INDEX IF NOT EXISTS idx_sync_data_type ON ${FT_SYNC_DATA_FLAT_TABLE_NAME} (${RECORD_COLUMN_DATA_TYPE})`,
  `CREATE INDEX IF NOT EXISTS idx_sync_data_time ON ${FT_SYNC_DATA_FLAT_TABLE_NAME} (${RECORD_COLUMN_TM})`,
  `CREATE INDEX IF NOT EXISTS idx_sync_data_type_time ON ${FT_SYNC_DATA_FLAT_TABLE_NAME} (${RECORD_COLUMN_DATA_TYPE}, ${RECORD_COLUMN_TM})`,
  `CREATE INDEX IF NOT EXISTS idx_rum_view_session ON ${FT_TABLE_VIEW} (${RUM_COLUMN_SESSION_ID})`,
  `CREATE INDEX IF NOT EXISTS idx_rum_view_time ON ${FT_TABLE_VIEW} (${RUM_COLUMN_START_TIME})`,
  `CREATE INDEX IF NOT EXISTS idx_rum_action_session ON ${FT_TABLE_ACTION} (${RUM_COLUMN_SESSION_ID})`,
  `CREATE INDEX IF NOT EXISTS idx_rum_action_time ON ${FT_TABLE_ACTION} (${RUM_COLUMN_START_TIME})`
];

/**
 * FTSQL class containing all SQL-related constants
 */
export class FTSQL {
  static readonly FT_SYNC_DATA_FLAT_TABLE_NAME = FT_SYNC_DATA_FLAT_TABLE_NAME;
  static readonly FT_TABLE_VIEW = FT_TABLE_VIEW;
  static readonly FT_TABLE_ACTION = FT_TABLE_ACTION;
  static readonly RECORD_COLUMN_ID = RECORD_COLUMN_ID;
  static readonly RECORD_COLUMN_TM = RECORD_COLUMN_TM;
  static readonly RECORD_COLUMN_DATA_UUID = RECORD_COLUMN_DATA_UUID;
  static readonly RECORD_COLUMN_DATA = RECORD_COLUMN_DATA;
  static readonly RECORD_COLUMN_DATA_TYPE = RECORD_COLUMN_DATA_TYPE;
  static readonly RUM_COLUMN_ID = RUM_COLUMN_ID;
  static readonly RUM_COLUMN_START_TIME = RUM_COLUMN_START_TIME;
  static readonly RUM_COLUMN_IS_CLOSE = RUM_COLUMN_IS_CLOSE;
  static readonly RUM_COLUMN_ERROR_COUNT = RUM_COLUMN_ERROR_COUNT;
  static readonly RUM_COLUMN_LONG_TASK_COUNT = RUM_COLUMN_LONG_TASK_COUNT;
  static readonly RUM_COLUMN_RESOURCE_COUNT = RUM_COLUMN_RESOURCE_COUNT;
  static readonly RUM_COLUMN_PENDING_RESOURCE = RUM_COLUMN_PENDING_RESOURCE;
  static readonly RUM_COLUMN_SESSION_ID = RUM_COLUMN_SESSION_ID;
  static readonly RUM_COLUMN_VIEW_NAME = RUM_COLUMN_VIEW_NAME;
  static readonly RUM_COLUMN_VIEW_ID = RUM_COLUMN_VIEW_ID;
  static readonly RUM_COLUMN_VIEW_REFERRER = RUM_COLUMN_VIEW_REFERRER;
  static readonly RUM_COLUMN_ACTION_COUNT = RUM_COLUMN_ACTION_COUNT;
  static readonly RUM_COLUMN_VIEW_LOAD_TIME = RUM_COLUMN_VIEW_LOAD_TIME;
  static readonly RUM_COLUMN_VIEW_TIME_SPENT = RUM_COLUMN_VIEW_TIME_SPENT;
  static readonly RUM_COLUMN_ACTION_NAME = RUM_COLUMN_ACTION_NAME;
  static readonly RUM_COLUMN_ACTION_TYPE = RUM_COLUMN_ACTION_TYPE;
  static readonly RUM_COLUMN_ACTION_DURATION = RUM_COLUMN_ACTION_DURATION;
  static readonly RUM_COLUMN_EXTRA_ATTR = RUM_COLUMN_EXTRA_ATTR;
  static readonly RUM_DATA_UPDATE_TIME = RUM_DATA_UPDATE_TIME;
  static readonly RUM_DATA_UPLOAD_TIME = RUM_DATA_UPLOAD_TIME;
  static readonly RUM_VIEW_UPDATE_TIME = RUM_VIEW_UPDATE_TIME;
  static readonly FT_TABLE_SYNC_CREATE = FT_TABLE_SYNC_CREATE;
  static readonly FT_TABLE_VIEW_CREATE = FT_TABLE_VIEW_CREATE;
  static readonly FT_TABLE_ACTION_CREATE = FT_TABLE_ACTION_CREATE;
  static readonly CREATE_INDEXES = CREATE_INDEXES;
}
