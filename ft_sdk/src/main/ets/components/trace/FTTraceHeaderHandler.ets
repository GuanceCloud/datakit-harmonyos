/**
 * Trace context generated for one request.
 */
export interface FTTraceContext {
  headers: Record<string, string>;
  traceId: string;
  spanId: string;
}

/**
 * Request context passed to custom Trace Header handlers.
 */
export interface FTTraceRequestContext {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: string | Object | ArrayBuffer;
}

/**
 * Trace Header generator interface.
 */
export interface FTTraceHeaderHandler {
  /**
   * Return Trace Headers, traceId, and spanId for the request.
   *
   * Use request.url to generate default Trace Headers when needed, then return
   * the final headers, traceId, and spanId together.
   */
  getTraceContext(request: FTTraceRequestContext): FTTraceContext;
}
