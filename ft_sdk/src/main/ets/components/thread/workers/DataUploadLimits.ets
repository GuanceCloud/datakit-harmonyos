/** Upload batching settings shared by the Host orchestrator and DataUploadWorker. */
export const DATA_UPLOAD_MAX_PAGE_SIZE: number = 500;
/**
 * Preferred Host-to-Worker batch size. It is deliberately not a per-record
 * limit: a first record larger than this value is sent on its own.
 */
export const DATA_UPLOAD_TRANSPORT_TARGET_BYTES: number = 768 * 1024;
/**
 * Preferred HTTP request batch size. It is deliberately not a per-record
 * limit: a first line larger than this value is sent on its own.
 */
export const DATA_UPLOAD_BODY_TARGET_BYTES: number = 1024 * 1024;
export const DATA_UPLOAD_MAX_RETRY_COUNT: number = 5;
export const DATA_UPLOAD_LIMIT_RETRY_DELAY_MS: number = 500;
