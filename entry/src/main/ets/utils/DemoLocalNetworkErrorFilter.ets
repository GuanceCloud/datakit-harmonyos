import {
  FTNetworkErrorContext,
  FTNetworkErrorHandler,
  FTNetworkResourceFields
} from '@guancecloud/ft_sdk/Index';

/**
 * Demo-wide default for local network failures. It retains the Resource,
 * annotates it, and suppresses only the SDK-derived network Error.
 */
export class DemoLocalNetworkErrorFilter implements FTNetworkErrorHandler {
  onExceptionWithFilter(context: FTNetworkErrorContext, resourceFields: FTNetworkResourceFields): boolean {
    resourceFields['demo_network_error_source'] = context.source;
    resourceFields['demo_network_error_kind'] = context.kind;
    resourceFields['demo_network_error_filtered'] = true;
    return true;
  }
}
