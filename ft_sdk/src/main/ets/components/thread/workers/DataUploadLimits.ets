/** Hard safety limits shared by the Host orchestrator and DataUploadWorker. */
export const DATA_UPLOAD_MAX_PAGE_SIZE: number = 500;
/** DB TaskPool DTO/Host-to-Worker cap, leaving headroom for package-id expansion. */
export const DATA_UPLOAD_MAX_TRANSPORT_BYTES: number = 768 * 1024;
export const DATA_UPLOAD_MAX_BODY_BYTES: number = 1024 * 1024;
export const DATA_UPLOAD_MAX_RETRY_COUNT: number = 5;
export const DATA_UPLOAD_LIMIT_RETRY_DELAY_MS: number = 500;
