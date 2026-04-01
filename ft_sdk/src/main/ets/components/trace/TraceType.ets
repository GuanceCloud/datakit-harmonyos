/**
 * Trace type enumeration
 * Used to set HTTP request trace using Header propagation
 */
export enum TraceType {
  /**
   * datadog trace, default value
   * x-datadog-trace-id
   * x-datadog-parent-id
   * x-datadog-sampling-priority
   * x-datadog-origin
   */
  DDTRACE = "ddtrace",

  /**
   * zipkin multi header
   * X-B3-TraceId
   * X-B3-SpanId
   * X-B3-Sampled
   */
  ZIPKIN_MULTI_HEADER = "zipkin_multi_header",

  /**
   * zipkin single header, b3
   */
  ZIPKIN_SINGLE_HEADER = "zipkin_single_header",

  /**
   * w3c, traceparent
   */
  TRACEPARENT = "traceparent",

  /**
   * skywalking 8.0+, sw-8
   */
  SKYWALKING = "skywalking",

  /**
   * jaeger, header uber-trace-id
   */
  JAEGER = "jaeger"
}

/**
 * TraceType utility class
 */
export class TraceTypeUtils {
  /**
   * Get string value of Trace type
   * @param traceType Trace type
   * @returns Lowercase string type, such as zipkin, ddtrace, etc.
   */
  static toString(traceType: TraceType): string {
    switch (traceType) {
      case TraceType.ZIPKIN_SINGLE_HEADER:
      case TraceType.ZIPKIN_MULTI_HEADER:
        // zipkin multi header and single header output same characters
        return "zipkin";
      default:
        return traceType.toLowerCase();
    }
  }

  /**
   * Get original value of Trace type
   * @param traceType Trace type
   * @returns Original enum value
   */
  static value(traceType: TraceType): string {
    return traceType.toLowerCase();
  }

  /**
   * Check if it is Zipkin type
   * @param traceType Trace type
   * @returns Whether it is Zipkin type
   */
  static isZipkin(traceType: TraceType): boolean {
    return traceType === TraceType.ZIPKIN_MULTI_HEADER || 
           traceType === TraceType.ZIPKIN_SINGLE_HEADER;
  }

  /**
   * Check if it is DataDog type
   * @param traceType Trace type
   * @returns Whether it is DataDog type
   */
  static isDataDog(traceType: TraceType): boolean {
    return traceType === TraceType.DDTRACE;
  }

  /**
   * Check if it is W3C type
   * @param traceType Trace type
   * @returns Whether it is W3C type
   */
  static isW3C(traceType: TraceType): boolean {
    return traceType === TraceType.TRACEPARENT;
  }

  /**
   * Check if it is SkyWalking type
   * @param traceType Trace type
   * @returns Whether it is SkyWalking type
   */
  static isSkyWalking(traceType: TraceType): boolean {
    return traceType === TraceType.SKYWALKING;
  }

  /**
   * Check if it is Jaeger type
   * @param traceType Trace type
   * @returns Whether it is Jaeger type
   */
  static isJaeger(traceType: TraceType): boolean {
    return traceType === TraceType.JAEGER;
  }
}
