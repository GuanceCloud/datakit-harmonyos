import { http } from '@kit.NetworkKit';
import { FTSDKConfig } from '../Configs';
import { Constants } from '../Constants';
import { HttpBuilder } from '../http/HttpBuilder';
import { FTInnerLogger } from '../log/FTLogger';
import {
  RemoteDataFilterHttpClient,
  RemoteDataFilterHttpResponse,
  RemoteDataFilterScheduler
} from './RemoteDataFilterTypes';

const TAG = 'FTRemoteDataFilterManager';
const FALLBACK_REFRESH_DELAY_MS = 10_000;

class DefaultRemoteDataFilterHttpClient implements RemoteDataFilterHttpClient {
  async fetch(config: FTSDKConfig): Promise<RemoteDataFilterHttpResponse> {
    const response = await HttpBuilder.Builder(config)
      .setModel(Constants.URL_DATAKIT_PULL)
      .addQueryParam('filters', 'true')
      .setMethod(http.RequestMethod.GET)
      .executeSync();
    return {
      code: response.getCode(),
      body: response.getMessage()
    };
  }
}

class DefaultRemoteDataFilterScheduler implements RemoteDataFilterScheduler {
  schedule(delayMs: number, callback: () => void): number {
    return setTimeout(callback, delayMs) as number;
  }

  cancel(timerId: number): void {
    clearTimeout(timerId);
  }
}

interface RemoteDataFilterPayload {
  filters: Map<string, Array<string>>;
  refreshDelayMs: number;
}

/**
 * Pulls DataKit-compatible remote blacklist rules. The manager deliberately
 * keeps transport and scheduling separate from filtering so FTTrackInner can
 * combine remote rules with application-provided rules in one evaluator.
 */
export class FTRemoteDataFilterManager {
  private readonly config: FTSDKConfig;
  private readonly endpointAvailable: () => boolean;
  private readonly onFiltersApplied: (filters: Map<string, Array<string>>) => void;
  private readonly httpClient: RemoteDataFilterHttpClient;
  private readonly scheduler: RemoteDataFilterScheduler;
  private timerId: number | null = null;
  private running: boolean = false;
  private closed: boolean = false;
  private endpointGeneration: number = 0;
  private refreshPending: boolean = false;

  public constructor(
    config: FTSDKConfig,
    endpointAvailable: () => boolean,
    onFiltersApplied: (filters: Map<string, Array<string>>) => void,
    httpClient: RemoteDataFilterHttpClient = new DefaultRemoteDataFilterHttpClient(),
    scheduler: RemoteDataFilterScheduler = new DefaultRemoteDataFilterScheduler()
  ) {
    this.config = config;
    this.endpointAvailable = endpointAvailable;
    this.onFiltersApplied = onFiltersApplied;
    this.httpClient = httpClient;
    this.scheduler = scheduler;
  }

  /** Start the first pull immediately when an intake endpoint is configured. */
  public start(): Promise<void> {
    return this.requestRefresh();
  }

  /**
   * Drop rules belonging to the old endpoint and immediately pull rules from
   * the active endpoint. Responses started before the switch are ignored.
   */
  public refreshForEndpointChange(): Promise<void> {
    this.endpointGeneration++;
    this.cancelScheduledRefresh();
    if (this.closed) {
      return Promise.resolve();
    }
    this.onFiltersApplied(new Map<string, Array<string>>());
    return this.requestRefresh();
  }

  public close(): void {
    this.closed = true;
    this.endpointGeneration++;
    this.refreshPending = false;
    this.cancelScheduledRefresh();
  }

  private requestRefresh(): Promise<void> {
    if (this.closed || !this.endpointAvailable()) {
      return Promise.resolve();
    }
    if (this.running) {
      this.refreshPending = true;
      return Promise.resolve();
    }
    return this.refresh();
  }

  private async refresh(): Promise<void> {
    this.running = true;
    const requestEndpointGeneration = this.endpointGeneration;
    try {
      const response = await this.httpClient.fetch(this.config);
      if (this.closed || requestEndpointGeneration !== this.endpointGeneration) {
        return;
      }
      if (response.code !== http.ResponseCode.OK) {
        this.scheduleRefresh(FALLBACK_REFRESH_DELAY_MS);
        return;
      }
      const payload = FTRemoteDataFilterManager.parsePayload(response.body);
      if (payload === null) {
        this.scheduleRefresh(FALLBACK_REFRESH_DELAY_MS);
        return;
      }
      this.onFiltersApplied(payload.filters);
      this.scheduleRefresh(payload.refreshDelayMs);
    } catch (error) {
      if (!this.closed && requestEndpointGeneration === this.endpointGeneration) {
        FTInnerLogger.w(TAG, `Remote data-filter refresh failed: ${String(error)}`);
        this.scheduleRefresh(FALLBACK_REFRESH_DELAY_MS);
      }
    } finally {
      this.running = false;
      if (this.refreshPending && !this.closed) {
        this.refreshPending = false;
        void this.requestRefresh();
      }
    }
  }

  private scheduleRefresh(delayMs: number): void {
    this.cancelScheduledRefresh();
    if (this.closed || !this.endpointAvailable()) {
      return;
    }
    this.timerId = this.scheduler.schedule(delayMs, () => {
      this.timerId = null;
      void this.requestRefresh();
    });
  }

  private cancelScheduledRefresh(): void {
    if (this.timerId !== null) {
      this.scheduler.cancel(this.timerId);
      this.timerId = null;
    }
  }

  private static parsePayload(body: string): RemoteDataFilterPayload | null {
    try {
      const root = JSON.parse(body) as Record<string, Object>;
      const value = root['filters'];
      if (value === null || typeof value !== 'object' || Array.isArray(value)) {
        return null;
      }
      const rawFilters = value as Record<string, Object>;
      const filters = new Map<string, Array<string>>();
      FTRemoteDataFilterManager.readCategory(rawFilters, 'logging', filters);
      FTRemoteDataFilterManager.readCategory(rawFilters, 'rum', filters);
      return {
        filters,
        refreshDelayMs: FTRemoteDataFilterManager.parsePullInterval(root['pull_interval'])
      };
    } catch (_error) {
      return null;
    }
  }

  private static readCategory(
    rawFilters: Record<string, Object>,
    category: string,
    target: Map<string, Array<string>>
  ): void {
    const value = rawFilters[category];
    if (!Array.isArray(value)) {
      return;
    }
    const rules: Array<string> = [];
    for (let index = 0; index < value.length; index++) {
      if (typeof value[index] === 'string') {
        rules.push(value[index] as string);
      }
    }
    target.set(category, rules);
  }

  private static parsePullInterval(value: Object | undefined): number {
    if (typeof value === 'number') {
      return FTRemoteDataFilterManager.toDelayMs(value);
    }
    if (typeof value !== 'string') {
      return FALLBACK_REFRESH_DELAY_MS;
    }
    const input = value.trim().toLowerCase();
    if (input.length === 0) {
      return FALLBACK_REFRESH_DELAY_MS;
    }
    const numeric = Number(input);
    if (!Number.isNaN(numeric)) {
      return FTRemoteDataFilterManager.toDelayMs(numeric);
    }

    let offset = 0;
    let totalMs = 0;
    while (offset < input.length) {
      const numberStart = offset;
      while (offset < input.length &&
        ((input.charAt(offset) >= '0' && input.charAt(offset) <= '9') || input.charAt(offset) === '.')) {
        offset++;
      }
      if (numberStart === offset) {
        return FALLBACK_REFRESH_DELAY_MS;
      }
      const amount = Number(input.substring(numberStart, offset));
      if (!Number.isFinite(amount) || amount <= 0) {
        return FALLBACK_REFRESH_DELAY_MS;
      }
      let multiplier = 0;
      if (input.substring(offset, offset + 2) === 'ms') {
        multiplier = 1;
        offset += 2;
      } else {
        const unit = input.charAt(offset);
        if (unit === 's') multiplier = 1_000;
        else if (unit === 'm') multiplier = 60_000;
        else if (unit === 'h') multiplier = 3_600_000;
        else return FALLBACK_REFRESH_DELAY_MS;
        offset++;
      }
      totalMs += amount * multiplier;
    }
    return FTRemoteDataFilterManager.toDelayMs(totalMs / 1_000);
  }

  private static toDelayMs(seconds: number): number {
    if (!Number.isFinite(seconds) || seconds <= 0) {
      return FALLBACK_REFRESH_DELAY_MS;
    }
    return Math.max(1, Math.floor(seconds * 1_000));
  }
}
