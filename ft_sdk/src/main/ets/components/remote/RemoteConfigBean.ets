/**
 * Android-compatible representation of the payload returned by
 * /v1/env_variable. Unknown content keys are retained when a fetch callback
 * modifies and persists the configuration.
 */
export class RemoteConfigBean {
  public static readonly KEY_SERVICE_NAME: string = 'serviceName';
  public static readonly KEY_AUTO_SYNC: string = 'autoSync';
  public static readonly KEY_COMPRESS_INTAKE_REQUESTS: string = 'compressIntakeRequests';
  public static readonly KEY_SYNC_PAGE_SIZE: string = 'syncPageSize';
  public static readonly KEY_SYNC_SLEEP_TIME: string = 'syncSleepTime';
  public static readonly KEY_RUM_SAMPLE_RATE: string = 'rumSampleRate';
  public static readonly KEY_RUM_SESSION_ON_ERROR_SAMPLE_RATE: string = 'rumSessionOnErrorSampleRate';
  public static readonly KEY_RUM_ENABLE_TRACE_USER_ACTION: string = 'rumEnableTraceUserAction';
  public static readonly KEY_RUM_ENABLE_TRACE_USER_VIEW: string = 'rumEnableTraceUserView';
  public static readonly KEY_RUM_ENABLE_TRACE_USER_RESOURCE: string = 'rumEnableTraceUserResource';
  public static readonly KEY_RUM_ENABLE_RESOURCE_HOST_IP: string = 'rumEnableResourceHostIP';
  public static readonly KEY_RUM_ENABLE_TRACK_APP_UIBLOCK: string = 'rumEnableTrackAppUIBlock';
  public static readonly KEY_RUM_BLOCK_DURATION_MS: string = 'rumBlockDurationMs';
  public static readonly KEY_RUM_ENABLE_TRACK_APP_CRASH: string = 'rumEnableTrackAppCrash';
  public static readonly KEY_RUM_ENABLE_TRACK_APP_ANR: string = 'rumEnableTrackAppANR';
  public static readonly KEY_RUM_ENABLE_TRACE_WEB_VIEW: string = 'rumEnableTraceWebView';
  public static readonly KEY_RUM_ALLOW_WEB_VIEW_HOST: string = 'rumAllowWebViewHost';
  public static readonly KEY_LOG_SAMPLE_RATE: string = 'logSampleRate';
  public static readonly KEY_LOG_LEVEL_FILTERS: string = 'logLevelFilters';
  public static readonly KEY_LOG_ENABLE_CUSTOM_LOG: string = 'logEnableCustomLog';
  public static readonly KEY_LOG_ENABLE_CONSOLE_LOG: string = 'logEnableConsoleLog';
  public static readonly KEY_TRACE_SAMPLE_RATE: string = 'traceSampleRate';
  public static readonly KEY_TRACE_ENABLE_AUTO_TRACE: string = 'traceEnableAutoTrace';
  public static readonly KEY_TRACE_TYPE: string = 'traceType';
  public static readonly KEY_SESSION_REPLAY_SAMPLE_RATE: string = 'sessionReplaySampleRate';
  public static readonly KEY_SESSION_REPLAY_ON_ERROR_SAMPLE_RATE: string = 'sessionReplayOnErrorSampleRate';
  public static readonly KEY_ENV: string = 'env';
  public static readonly KEY_MD5: string = 'md5';

  private env: string | null = null;
  private serviceName: string | null = null;
  private autoSync: boolean | null = null;
  private compressIntakeRequests: boolean | null = null;
  private syncPageSize: number | null = null;
  private syncSleepTime: number | null = null;
  private rumSampleRate: number | null = null;
  private rumSessionOnErrorSampleRate: number | null = null;
  private rumEnableTraceUserAction: boolean | null = null;
  private rumEnableTraceUserView: boolean | null = null;
  private rumEnableTraceUserResource: boolean | null = null;
  private rumEnableResourceHostIP: boolean | null = null;
  private rumEnableTrackAppUIBlock: boolean | null = null;
  private rumBlockDurationMs: number | null = null;
  private rumEnableTrackAppCrash: boolean | null = null;
  private rumEnableTrackAppANR: boolean | null = null;
  private rumEnableTraceWebView: boolean | null = null;
  private rumAllowWebViewHost: Array<string> | null = null;
  private logSampleRate: number | null = null;
  private logLevelFilters: Array<string> | null = null;
  private logEnableCustomLog: boolean | null = null;
  private logEnableConsoleLog: boolean | null = null;
  private traceSampleRate: number | null = null;
  private traceEnableAutoTrace: boolean | null = null;
  private traceType: string | null = null;
  private sessionReplaySampleRate: number | null = null;
  private sessionReplayOnErrorSampleRate: number | null = null;
  private md5: string | null = null;
  private valid: boolean = false;
  private contentJsonString: string = '';

  public static buildFromConfigJson(json: string, md5?: string): RemoteConfigBean {
    const bean = new RemoteConfigBean();
    bean.parse(json);
    if (md5 !== undefined) {
      bean.md5 = md5;
    }
    return bean;
  }

  private parse(json: string): void {
    try {
      const root = JSON.parse(json) as Record<string, Object>;
      const rootMd5 = root[RemoteConfigBean.KEY_MD5];
      if (typeof rootMd5 === 'string') {
        this.md5 = rootMd5;
      }
      const contentValue = root['content'];
      let content: Record<string, Object>;
      if (typeof contentValue === 'string') {
        content = JSON.parse(contentValue) as Record<string, Object>;
      } else if (contentValue !== null && typeof contentValue === 'object' && !Array.isArray(contentValue)) {
        content = contentValue as Record<string, Object>;
      } else {
        return;
      }
      this.contentJsonString = JSON.stringify(content);
      this.env = RemoteConfigBean.readString(content, RemoteConfigBean.KEY_ENV);
      this.serviceName = RemoteConfigBean.readString(content, RemoteConfigBean.KEY_SERVICE_NAME);
      this.autoSync = RemoteConfigBean.readBoolean(content, RemoteConfigBean.KEY_AUTO_SYNC);
      this.compressIntakeRequests = RemoteConfigBean.readBoolean(content, RemoteConfigBean.KEY_COMPRESS_INTAKE_REQUESTS);
      this.syncPageSize = RemoteConfigBean.readNumber(content, RemoteConfigBean.KEY_SYNC_PAGE_SIZE);
      this.syncSleepTime = RemoteConfigBean.readNumber(content, RemoteConfigBean.KEY_SYNC_SLEEP_TIME);
      this.rumSampleRate = RemoteConfigBean.readNumber(content, RemoteConfigBean.KEY_RUM_SAMPLE_RATE);
      this.rumSessionOnErrorSampleRate = RemoteConfigBean.readNumber(content, RemoteConfigBean.KEY_RUM_SESSION_ON_ERROR_SAMPLE_RATE);
      this.rumEnableTraceUserAction = RemoteConfigBean.readBoolean(content, RemoteConfigBean.KEY_RUM_ENABLE_TRACE_USER_ACTION);
      this.rumEnableTraceUserView = RemoteConfigBean.readBoolean(content, RemoteConfigBean.KEY_RUM_ENABLE_TRACE_USER_VIEW);
      this.rumEnableTraceUserResource = RemoteConfigBean.readBoolean(content, RemoteConfigBean.KEY_RUM_ENABLE_TRACE_USER_RESOURCE);
      this.rumEnableResourceHostIP = RemoteConfigBean.readBoolean(content, RemoteConfigBean.KEY_RUM_ENABLE_RESOURCE_HOST_IP);
      this.rumEnableTrackAppUIBlock = RemoteConfigBean.readBoolean(content, RemoteConfigBean.KEY_RUM_ENABLE_TRACK_APP_UIBLOCK);
      this.rumBlockDurationMs = RemoteConfigBean.readNumber(content, RemoteConfigBean.KEY_RUM_BLOCK_DURATION_MS);
      this.rumEnableTrackAppCrash = RemoteConfigBean.readBoolean(content, RemoteConfigBean.KEY_RUM_ENABLE_TRACK_APP_CRASH);
      this.rumEnableTrackAppANR = RemoteConfigBean.readBoolean(content, RemoteConfigBean.KEY_RUM_ENABLE_TRACK_APP_ANR);
      this.rumEnableTraceWebView = RemoteConfigBean.readBoolean(content, RemoteConfigBean.KEY_RUM_ENABLE_TRACE_WEB_VIEW);
      this.rumAllowWebViewHost = RemoteConfigBean.readStringArray(content, RemoteConfigBean.KEY_RUM_ALLOW_WEB_VIEW_HOST);
      this.logSampleRate = RemoteConfigBean.readNumber(content, RemoteConfigBean.KEY_LOG_SAMPLE_RATE);
      this.logLevelFilters = RemoteConfigBean.readStringArray(content, RemoteConfigBean.KEY_LOG_LEVEL_FILTERS);
      this.logEnableCustomLog = RemoteConfigBean.readBoolean(content, RemoteConfigBean.KEY_LOG_ENABLE_CUSTOM_LOG);
      this.logEnableConsoleLog = RemoteConfigBean.readBoolean(content, RemoteConfigBean.KEY_LOG_ENABLE_CONSOLE_LOG);
      this.traceSampleRate = RemoteConfigBean.readNumber(content, RemoteConfigBean.KEY_TRACE_SAMPLE_RATE);
      this.traceEnableAutoTrace = RemoteConfigBean.readBoolean(content, RemoteConfigBean.KEY_TRACE_ENABLE_AUTO_TRACE);
      this.traceType = RemoteConfigBean.readString(content, RemoteConfigBean.KEY_TRACE_TYPE);
      this.sessionReplaySampleRate = RemoteConfigBean.readNumber(content, RemoteConfigBean.KEY_SESSION_REPLAY_SAMPLE_RATE);
      this.sessionReplayOnErrorSampleRate = RemoteConfigBean.readNumber(content, RemoteConfigBean.KEY_SESSION_REPLAY_ON_ERROR_SAMPLE_RATE);
      this.valid = true;
    } catch (_) {
      this.valid = false;
    }
  }

  private static readString(content: Record<string, Object>, key: string): string | null {
    const value = content[key];
    return typeof value === 'string' ? value : null;
  }

  private static readBoolean(content: Record<string, Object>, key: string): boolean | null {
    const value = content[key];
    return typeof value === 'boolean' ? value : null;
  }

  private static readNumber(content: Record<string, Object>, key: string): number | null {
    const value = content[key];
    return typeof value === 'number' && isFinite(value) ? value : null;
  }

  private static readStringArray(content: Record<string, Object>, key: string): Array<string> | null {
    let value = content[key];
    try {
      if (typeof value === 'string') {
        value = JSON.parse(value) as Object;
      }
      if (!Array.isArray(value)) {
        return null;
      }
      const result: Array<string> = [];
      for (let index = 0; index < value.length; index++) {
        if (typeof value[index] !== 'string') {
          return null;
        }
        result.push(value[index] as string);
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  private writeToContent(content: Record<string, Object>, key: string, value: Object | null): void {
    if (value !== null) {
      content[key] = value;
    }
  }

  public toJsonString(): string {
    try {
      let content: Record<string, Object> = {};
      if (this.contentJsonString.length > 0) {
        content = JSON.parse(this.contentJsonString) as Record<string, Object>;
      }
      this.writeToContent(content, RemoteConfigBean.KEY_ENV, this.env as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_SERVICE_NAME, this.serviceName as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_AUTO_SYNC, this.autoSync as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_COMPRESS_INTAKE_REQUESTS, this.compressIntakeRequests as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_SYNC_PAGE_SIZE, this.syncPageSize as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_SYNC_SLEEP_TIME, this.syncSleepTime as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_RUM_SAMPLE_RATE, this.rumSampleRate as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_RUM_SESSION_ON_ERROR_SAMPLE_RATE, this.rumSessionOnErrorSampleRate as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_RUM_ENABLE_TRACE_USER_ACTION, this.rumEnableTraceUserAction as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_RUM_ENABLE_TRACE_USER_VIEW, this.rumEnableTraceUserView as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_RUM_ENABLE_TRACE_USER_RESOURCE, this.rumEnableTraceUserResource as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_RUM_ENABLE_RESOURCE_HOST_IP, this.rumEnableResourceHostIP as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_RUM_ENABLE_TRACK_APP_UIBLOCK, this.rumEnableTrackAppUIBlock as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_RUM_BLOCK_DURATION_MS, this.rumBlockDurationMs as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_RUM_ENABLE_TRACK_APP_CRASH, this.rumEnableTrackAppCrash as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_RUM_ENABLE_TRACK_APP_ANR, this.rumEnableTrackAppANR as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_RUM_ENABLE_TRACE_WEB_VIEW, this.rumEnableTraceWebView as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_RUM_ALLOW_WEB_VIEW_HOST, this.rumAllowWebViewHost as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_LOG_SAMPLE_RATE, this.logSampleRate as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_LOG_LEVEL_FILTERS, this.logLevelFilters as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_LOG_ENABLE_CUSTOM_LOG, this.logEnableCustomLog as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_LOG_ENABLE_CONSOLE_LOG, this.logEnableConsoleLog as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_TRACE_SAMPLE_RATE, this.traceSampleRate as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_TRACE_ENABLE_AUTO_TRACE, this.traceEnableAutoTrace as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_TRACE_TYPE, this.traceType as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_SESSION_REPLAY_SAMPLE_RATE, this.sessionReplaySampleRate as Object | null);
      this.writeToContent(content, RemoteConfigBean.KEY_SESSION_REPLAY_ON_ERROR_SAMPLE_RATE, this.sessionReplayOnErrorSampleRate as Object | null);
      const root: Record<string, Object> = {};
      root['content'] = content;
      if (this.md5 !== null) {
        root[RemoteConfigBean.KEY_MD5] = this.md5;
      }
      return JSON.stringify(root);
    } catch (_) {
      return '';
    }
  }

  public isValid(): boolean { return this.valid; }
  public getMd5(): string | null { return this.md5; }
  public getContentJsonString(): string { return this.contentJsonString; }
  public getEnv(): string | null { return this.env; }
  public getServiceName(): string | null { return this.serviceName; }
  public getAutoSync(): boolean | null { return this.autoSync; }
  public getCompressIntakeRequests(): boolean | null { return this.compressIntakeRequests; }
  public getSyncPageSize(): number | null { return this.syncPageSize; }
  public getSyncSleepTime(): number | null { return this.syncSleepTime; }
  public getRumSampleRate(): number | null { return this.rumSampleRate; }
  public getRumSessionOnErrorSampleRate(): number | null { return this.rumSessionOnErrorSampleRate; }
  public getRumEnableTraceUserAction(): boolean | null { return this.rumEnableTraceUserAction; }
  public getRumEnableTraceUserView(): boolean | null { return this.rumEnableTraceUserView; }
  public getRumEnableTraceUserResource(): boolean | null { return this.rumEnableTraceUserResource; }
  public getRumEnableResourceHostIP(): boolean | null { return this.rumEnableResourceHostIP; }
  public getRumEnableTrackAppUIBlock(): boolean | null { return this.rumEnableTrackAppUIBlock; }
  public getRumBlockDurationMs(): number | null { return this.rumBlockDurationMs; }
  public getRumEnableTrackAppCrash(): boolean | null { return this.rumEnableTrackAppCrash; }
  public getRumEnableTrackAppANR(): boolean | null { return this.rumEnableTrackAppANR; }
  public getRumEnableTraceWebView(): boolean | null { return this.rumEnableTraceWebView; }
  public getRumAllowWebViewHost(): Array<string> | null { return this.rumAllowWebViewHost === null ? null : this.rumAllowWebViewHost.slice(); }
  public getLogSampleRate(): number | null { return this.logSampleRate; }
  public getLogLevelFilters(): Array<string> | null { return this.logLevelFilters === null ? null : this.logLevelFilters.slice(); }
  public getLogEnableCustomLog(): boolean | null { return this.logEnableCustomLog; }
  public getLogEnableConsoleLog(): boolean | null { return this.logEnableConsoleLog; }
  public getTraceSampleRate(): number | null { return this.traceSampleRate; }
  public getTraceEnableAutoTrace(): boolean | null { return this.traceEnableAutoTrace; }
  public getTraceType(): string | null { return this.traceType; }
  public getSessionReplaySampleRate(): number | null { return this.sessionReplaySampleRate; }
  public getSessionReplayOnErrorSampleRate(): number | null { return this.sessionReplayOnErrorSampleRate; }

  public setEnv(value: string | null): void { this.env = value; }
  public setServiceName(value: string | null): void { this.serviceName = value; }
  public setAutoSync(value: boolean | null): void { this.autoSync = value; }
  public setCompressIntakeRequests(value: boolean | null): void { this.compressIntakeRequests = value; }
  public setSyncPageSize(value: number | null): void { this.syncPageSize = value; }
  public setSyncSleepTime(value: number | null): void { this.syncSleepTime = value; }
  public setRumSampleRate(value: number | null): void { this.rumSampleRate = value; }
  public setRumSessionOnErrorSampleRate(value: number | null): void { this.rumSessionOnErrorSampleRate = value; }
  public setRumEnableTraceUserAction(value: boolean | null): void { this.rumEnableTraceUserAction = value; }
  public setRumEnableTraceUserView(value: boolean | null): void { this.rumEnableTraceUserView = value; }
  public setRumEnableTraceUserResource(value: boolean | null): void { this.rumEnableTraceUserResource = value; }
  public setRumEnableResourceHostIP(value: boolean | null): void { this.rumEnableResourceHostIP = value; }
  public setRumEnableTrackAppUIBlock(value: boolean | null): void { this.rumEnableTrackAppUIBlock = value; }
  public setRumBlockDurationMs(value: number | null): void { this.rumBlockDurationMs = value; }
  public setRumEnableTrackAppCrash(value: boolean | null): void { this.rumEnableTrackAppCrash = value; }
  public setRumEnableTrackAppANR(value: boolean | null): void { this.rumEnableTrackAppANR = value; }
  public setRumEnableTraceWebView(value: boolean | null): void { this.rumEnableTraceWebView = value; }
  public setRumAllowWebViewHost(value: Array<string> | null): void { this.rumAllowWebViewHost = value === null ? null : value.slice(); }
  public setLogSampleRate(value: number | null): void { this.logSampleRate = value; }
  public setLogLevelFilters(value: Array<string> | null): void { this.logLevelFilters = value === null ? null : value.slice(); }
  public setLogEnableCustomLog(value: boolean | null): void { this.logEnableCustomLog = value; }
  public setLogEnableConsoleLog(value: boolean | null): void { this.logEnableConsoleLog = value; }
  public setTraceSampleRate(value: number | null): void { this.traceSampleRate = value; }
  public setTraceEnableAutoTrace(value: boolean | null): void { this.traceEnableAutoTrace = value; }
  public setTraceType(value: string | null): void { this.traceType = value; }
  public setSessionReplaySampleRate(value: number | null): void { this.sessionReplaySampleRate = value; }
  public setSessionReplayOnErrorSampleRate(value: number | null): void { this.sessionReplayOnErrorSampleRate = value; }
}
