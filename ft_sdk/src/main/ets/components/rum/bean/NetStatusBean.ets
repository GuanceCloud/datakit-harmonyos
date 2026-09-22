import {
  ResourceTransportMetrics,
  ResourceTransportMetricsSnapshot
} from './ResourceTransportMetrics';

/**
 * JSON representation interface for NetStatusBean
 */
interface NetStatusBeanJSON {
  dnsTime: number;
  dnsStartTime: number;
  tcpTime: number;
  tcpStartTime: number;
  sslTime: number;
  sslStartTime: number;
  ttfbTime: number;
  responseTime: number;
  firstByteTime: number;
  firstByteStartTime: number;
  downloadTime: number;
  downloadStartTime: number;
  holeRequestTime: number;
  resourceHostIP: string;
  transportMetrics: ResourceTransportMetricsSnapshot;
}

/**
 * Network status Bean class
 * Reference HarmonyOS NetStatusBean implementation
 */
export class NetStatusBean {
  // DNS related
  private dnsTime: number = -1;
  private dnsStartTime: number = -1;

  // TCP related
  private tcpTime: number = -1;
  private tcpStartTime: number = -1;

  // SSL related
  private sslTime: number = -1;
  private sslStartTime: number = -1;

  // TTFB related
  private ttfbTime: number = -1;

  // Response time
  private responseTime: number = -1;

  // First byte time
  private firstByteTime: number = -1;
  private firstByteStartTime: number = -1;

  // Download time
  private downloadTime: number = -1;
  private downloadStartTime: number = -1;

  // Complete request time
  private holeRequestTime: number = -1;

  // Host IP
  public resourceHostIP: string = "";

  /** Deferred platform transport observations associated with this Resource. */
  private readonly transportMetrics: ResourceTransportMetrics = new ResourceTransportMetrics();

  constructor() {
    // Constructor
  }

  /**
   * Get DNS resolution time
   */
  public getDNSTime(): number {
    return this.dnsTime;
  }

  /**
   * Set DNS resolution time
   */
  public setDNSTime(dnsTime: number): void {
    this.dnsTime = dnsTime;
  }

  /**
   * Get DNS start time
   */
  public getDNSStartTime(): number {
    return this.dnsStartTime;
  }

  /**
   * Set DNS start time
   */
  public setDNSStartTime(dnsStartTime: number): void {
    this.dnsStartTime = dnsStartTime;
  }

  /**
   * Get TCP connection time
   */
  public getTcpTime(): number {
    return this.tcpTime;
  }

  /**
   * Set TCP connection time
   */
  public setTcpTime(tcpTime: number): void {
    this.tcpTime = tcpTime;
  }

  /**
   * Get TCP connection start time
   */
  public getConnectStartTime(): number {
    return this.tcpStartTime;
  }

  /**
   * Set TCP connection start time
   */
  public setConnectStartTime(tcpStartTime: number): void {
    this.tcpStartTime = tcpStartTime;
  }

  /**
   * Get SSL handshake time
   */
  public getSSLTime(): number {
    return this.sslTime;
  }

  /**
   * Set SSL handshake time
   */
  public setSSLTime(sslTime: number): void {
    this.sslTime = sslTime;
  }

  /**
   * Get SSL handshake start time
   */
  public getSslStartTime(): number {
    return this.sslStartTime;
  }

  /**
   * Set SSL handshake start time
   */
  public setSslStartTime(sslStartTime: number): void {
    this.sslStartTime = sslStartTime;
  }

  /**
   * Get TTFB time
   */
  public getTTFB(): number {
    return this.ttfbTime;
  }

  /**
   * Set TTFB time
   */
  public setTTFB(ttfbTime: number): void {
    this.ttfbTime = ttfbTime;
  }

  /**
   * Get response time
   */
  public getResponseTime(): number {
    return this.responseTime;
  }

  /**
   * Set response time
   */
  public setResponseTime(responseTime: number): void {
    this.responseTime = responseTime;
  }

  /**
   * Get first byte time
   */
  public getFirstByteTime(): number {
    return this.firstByteTime;
  }

  /**
   * Set first byte time
   */
  public setFirstByteTime(firstByteTime: number): void {
    this.firstByteTime = firstByteTime;
  }

  /**
   * Get first byte start time
   */
  public getFirstByteStartTime(): number {
    return this.firstByteStartTime;
  }

  /**
   * Set first byte start time
   */
  public setFirstByteStartTime(firstByteStartTime: number): void {
    this.firstByteStartTime = firstByteStartTime;
  }

  /**
   * Get download time
   */
  public getDownloadTime(): number {
    return this.downloadTime;
  }

  /**
   * Set download time
   */
  public setDownloadTime(downloadTime: number): void {
    this.downloadTime = downloadTime;
  }

  /**
   * Get download start time
   */
  public getDownloadTimeStart(): number {
    return this.downloadStartTime;
  }

  /**
   * Set download start time
   */
  public setDownloadTimeStart(downloadStartTime: number): void {
    this.downloadStartTime = downloadStartTime;
  }

  /**
   * Get complete request time
   */
  public getHoleRequestTime(): number {
    return this.holeRequestTime;
  }

  /**
   * Set complete request time
   */
  public setHoleRequestTime(holeRequestTime: number): void {
    this.holeRequestTime = holeRequestTime;
  }

  /**
   * Set host IP
   */
  public setResourceHostIP(hostIP: string): void {
    this.resourceHostIP = hostIP || "";
  }

  /**
   * Get host IP
   */
  public getResourceHostIP(): string {
    return this.resourceHostIP;
  }

  /**
   * NetStatus is populated by automatic collectors, so these values have
   * platform precedence when merged with ResourceParams in the Worker.
   */
  public setPlatformRequestBodySize(size: number): void {
    this.transportMetrics.setRequestBodySize(size, 'platform');
  }

  public setPlatformRequestHeaderSize(size: number): void {
    this.transportMetrics.setRequestHeaderSize(size, 'platform');
  }

  public setPlatformRequestSize(size: number): void {
    this.transportMetrics.setRequestSize(size, 'platform');
  }

  public setPlatformHttpProtocol(protocol: string): void {
    this.transportMetrics.setHttpProtocol(protocol, 'platform');
  }

  public setPlatformConnectionReuse(connectionReuse: boolean): void {
    this.transportMetrics.setConnectionReuse(connectionReuse, 'platform');
  }

  public getTransportMetrics(): ResourceTransportMetricsSnapshot {
    return this.transportMetrics.snapshot();
  }

  public mergeTransportMetrics(metrics?: ResourceTransportMetricsSnapshot): void {
    this.transportMetrics.merge(metrics);
  }

  /**
   * Convert to JSON
   */
  public toJSON(): NetStatusBeanJSON {
    const result: NetStatusBeanJSON = {
      dnsTime: this.dnsTime,
      dnsStartTime: this.dnsStartTime,
      tcpTime: this.tcpTime,
      tcpStartTime: this.tcpStartTime,
      sslTime: this.sslTime,
      sslStartTime: this.sslStartTime,
      ttfbTime: this.ttfbTime,
      responseTime: this.responseTime,
      firstByteTime: this.firstByteTime,
      firstByteStartTime: this.firstByteStartTime,
      downloadTime: this.downloadTime,
      downloadStartTime: this.downloadStartTime,
      holeRequestTime: this.holeRequestTime,
      resourceHostIP: this.resourceHostIP,
      transportMetrics: this.transportMetrics.snapshot()
    };
    return result;
  }
}
