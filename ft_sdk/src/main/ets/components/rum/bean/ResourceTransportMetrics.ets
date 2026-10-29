/**
 * Origin of a Resource transport value. A value with a higher-ranked origin
 * must not be replaced by a lower-confidence observation for the same
 * Resource.
 */
export type ResourceTransportMetricSource = 'header' | 'integration' | 'platform';

export interface ResourceTransportMetricsSnapshot {
  requestBodySize: number;
  requestBodySizeSource?: ResourceTransportMetricSource;
  requestHeaderSize: number;
  requestHeaderSizeSource?: ResourceTransportMetricSource;
  requestSize: number;
  requestSizeSource?: ResourceTransportMetricSource;
  /** True only when requestSize was calculated from the two component sizes. */
  requestSizeIsDerived?: boolean;
  httpProtocol: string;
  httpProtocolSource?: ResourceTransportMetricSource;
  connectionReuse?: boolean;
  connectionReuseSource?: ResourceTransportMetricSource;
}

function sourceRank(source?: ResourceTransportMetricSource): number {
  if (source === 'platform') {
    return 3;
  }
  if (source === 'integration') {
    return 2;
  }
  if (source === 'header') {
    return 1;
  }
  return 0;
}

export function isValidResourceByteSize(value: number | undefined): boolean {
  return value !== undefined && Number.isSafeInteger(value) && value >= 0;
}

/** Shared by manual Resources, automatic collectors and recovered Worker DTOs. */
export function normalizeResourceHttpProtocol(protocol?: string): string | undefined {
  const value = typeof protocol === 'string' ? protocol.trim().toLowerCase() : '';
  if (value === '1.0' || value === 'http/1.0') return 'http/1.0';
  if (value === '1.1' || value === 'http/1.1') return 'http/1.1';
  if (value === '2' || value === 'h2' || value === 'http/2' || value === 'http/2.0' ||
    value === 'http/2 over tls') return 'h2';
  if (value === '3' || value === 'h3' || value === 'http/3' || value === 'http/3.0') return 'h3';
  return undefined;
}

/**
 * Mutable, serializable-safe Resource transport metrics. Sizes use -1 for an
 * unknown value, while zero remains a valid known size (for example an empty
 * request body).
 */
export class ResourceTransportMetrics {
  private requestBodySize: number = -1;
  private requestBodySizeSource?: ResourceTransportMetricSource;
  private requestHeaderSize: number = -1;
  private requestHeaderSizeSource?: ResourceTransportMetricSource;
  private requestSize: number = -1;
  private requestSizeSource?: ResourceTransportMetricSource;
  private requestSizeIsDerived: boolean = false;
  private httpProtocol: string = '';
  private httpProtocolSource?: ResourceTransportMetricSource;
  private connectionReuse?: boolean;
  private connectionReuseSource?: ResourceTransportMetricSource;

  public setRequestBodySize(value: number, source: ResourceTransportMetricSource): void {
    if (!isValidResourceByteSize(value) || sourceRank(source) < sourceRank(this.requestBodySizeSource)) {
      return;
    }
    this.requestBodySize = value;
    this.requestBodySizeSource = source;
    this.deriveRequestSizeIfPossible();
  }

  public setRequestHeaderSize(value: number, source: ResourceTransportMetricSource): void {
    if (!isValidResourceByteSize(value) || sourceRank(source) < sourceRank(this.requestHeaderSizeSource)) {
      return;
    }
    this.requestHeaderSize = value;
    this.requestHeaderSizeSource = source;
    this.deriveRequestSizeIfPossible();
  }

  public setRequestSize(value: number, source: ResourceTransportMetricSource): void {
    if (!isValidResourceByteSize(value) || sourceRank(source) < sourceRank(this.requestSizeSource)) {
      return;
    }
    this.requestSize = value;
    this.requestSizeSource = source;
    this.requestSizeIsDerived = false;
  }

  public setHttpProtocol(value: string, source: ResourceTransportMetricSource): void {
    const normalized = normalizeResourceHttpProtocol(value);
    if (normalized === undefined || sourceRank(source) < sourceRank(this.httpProtocolSource)) {
      return;
    }
    this.httpProtocol = normalized;
    this.httpProtocolSource = source;
  }

  public setConnectionReuse(value: boolean | undefined, source: ResourceTransportMetricSource): void {
    if (typeof value !== 'boolean' || sourceRank(source) < sourceRank(this.connectionReuseSource)) {
      return;
    }
    this.connectionReuse = value;
    this.connectionReuseSource = source;
  }

  public merge(snapshot?: ResourceTransportMetricsSnapshot): void {
    if (!snapshot) {
      return;
    }
    if (snapshot.requestBodySizeSource) {
      this.setRequestBodySize(snapshot.requestBodySize, snapshot.requestBodySizeSource);
    }
    if (snapshot.requestHeaderSizeSource) {
      this.setRequestHeaderSize(snapshot.requestHeaderSize, snapshot.requestHeaderSizeSource);
    }
    // A derived total must stay derived after crossing the async Resource
    // boundary. Otherwise a later platform body/header value cannot recalculate
    // it and an old inferred total can mask the platform observation.
    if (snapshot.requestSizeSource && snapshot.requestSizeIsDerived !== true) {
      this.setRequestSize(snapshot.requestSize, snapshot.requestSizeSource);
    }
    if (snapshot.httpProtocolSource) {
      this.setHttpProtocol(snapshot.httpProtocol, snapshot.httpProtocolSource);
    }
    if (snapshot.connectionReuseSource) {
      this.setConnectionReuse(snapshot.connectionReuse, snapshot.connectionReuseSource);
    }
  }

  public snapshot(): ResourceTransportMetricsSnapshot {
    return {
      requestBodySize: this.requestBodySize,
      requestBodySizeSource: this.requestBodySizeSource,
      requestHeaderSize: this.requestHeaderSize,
      requestHeaderSizeSource: this.requestHeaderSizeSource,
      requestSize: this.requestSize,
      requestSizeSource: this.requestSizeSource,
      requestSizeIsDerived: this.requestSizeIsDerived,
      httpProtocol: this.httpProtocol,
      httpProtocolSource: this.httpProtocolSource,
      connectionReuse: this.connectionReuse,
      connectionReuseSource: this.connectionReuseSource
    };
  }

  private deriveRequestSizeIfPossible(): void {
    if (!isValidResourceByteSize(this.requestBodySize) || !isValidResourceByteSize(this.requestHeaderSize) ||
      !this.requestBodySizeSource || !this.requestHeaderSizeSource) {
      return;
    }
    // A total built from a platform-observed component and a lower-priority
    // fallback must still replace a user-supplied total. The platform component
    // is the decisive observation for this Resource; the other component only
    // fills the part that the platform did not expose.
    const componentSource = sourceRank(this.requestBodySizeSource) >= sourceRank(this.requestHeaderSizeSource)
      ? this.requestBodySizeSource
      : this.requestHeaderSizeSource;
    // A direct total is authoritative only while it is at least as reliable as
    // both component values. For example, an integration may provide 40 at
    // request start, while the platform later exposes the actual 30-byte body
    // and 50-byte header. The platform total (80) must replace the earlier
    // integration value rather than remain masked by it.
    if (this.requestSizeSource && !this.requestSizeIsDerived &&
      sourceRank(this.requestSizeSource) >= sourceRank(componentSource)) {
      return;
    }
    const total = this.requestBodySize + this.requestHeaderSize;
    if (!isValidResourceByteSize(total)) {
      if (this.requestSizeIsDerived) {
        this.requestSize = -1;
        this.requestSizeSource = undefined;
        this.requestSizeIsDerived = false;
      }
      return;
    }
    this.requestSize = total;
    this.requestSizeSource = componentSource;
    this.requestSizeIsDerived = true;
  }
}
