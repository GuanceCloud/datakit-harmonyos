import {
  FTNetworkErrorContext,
  FTNetworkErrorHandler,
  FTNetworkErrorKind,
  FTNetworkResourceFields
} from '@guancecloud/ft_sdk/Index';

/**
 * Demo-wide default for local network failures. It retains the Resource,
 * annotates it, and suppresses every SDK-derived network Error.
 */
export class DemoGlobalNetworkErrorFilter implements FTNetworkErrorHandler {
  onExceptionWithFilter(context: FTNetworkErrorContext, resourceFields: FTNetworkResourceFields): boolean {
    resourceFields['demo_network_error_source'] = context.source;
    resourceFields['demo_network_error_kind'] = context.kind;
    resourceFields['demo_network_error_filtered'] = true;
    return true;
  }
}

/** Only the on-demand timeout and cancellation cases suppress their Error. */
export class DemoLocalNetworkErrorFilter implements FTNetworkErrorHandler {
  onExceptionWithFilter(context: FTNetworkErrorContext, resourceFields: FTNetworkResourceFields): boolean {
    resourceFields['demo_network_error_source'] = context.source;
    resourceFields['demo_network_error_kind'] = context.kind;
    const shouldFilter = context.kind === FTNetworkErrorKind.TIMEOUT ||
      context.kind === FTNetworkErrorKind.CANCELED;
    resourceFields['demo_network_error_filtered'] = shouldFilter;
    return shouldFilter;
  }
}
