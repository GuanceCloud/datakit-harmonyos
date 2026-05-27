export interface FakeAxiosRequestConfigTarget {
  url?: string;
  baseURL?: string;
  method?: string;
  headers?: Object;
  data?: Object | string | ArrayBuffer;
  context?: Object;
}

interface FakeAxiosResponseTarget {
  config: FakeAxiosRequestConfigTarget;
  status: number;
  headers?: Object;
  data?: Object | string | ArrayBuffer;
}

interface FakeAxiosInterceptors {
  request: FakeRequestInterceptorManager;
  response: FakeResponseInterceptorManager;
}

type RequestFulfilled = (value: FakeAxiosRequestConfigTarget) => FakeAxiosRequestConfigTarget | Promise<FakeAxiosRequestConfigTarget>;
type ResponseFulfilled = (value: FakeAxiosResponseTarget) => FakeAxiosResponseTarget | Promise<FakeAxiosResponseTarget>;
type RejectedHandler = (error: Object) => Object | Promise<Object>;

export class FakeRequestInterceptorManager {
  private fulfilled?: RequestFulfilled;

  public use(onFulfilled?: RequestFulfilled, _onRejected?: RejectedHandler): number {
    this.fulfilled = onFulfilled;
    return 1;
  }

  public run(config: FakeAxiosRequestConfigTarget): FakeAxiosRequestConfigTarget {
    if (!this.fulfilled) {
      return config;
    }
    return this.fulfilled(config) as FakeAxiosRequestConfigTarget;
  }
}

class FakeResponseInterceptorManager {
  public use(_onFulfilled?: ResponseFulfilled, _onRejected?: RejectedHandler): number {
    return 1;
  }
}

export class FakeAxiosTarget {
  public readonly requestManager: FakeRequestInterceptorManager = new FakeRequestInterceptorManager();
  public readonly interceptors: FakeAxiosInterceptors;

  constructor() {
    this.interceptors = {
      request: this.requestManager,
      response: new FakeResponseInterceptorManager()
    };
  }
}
