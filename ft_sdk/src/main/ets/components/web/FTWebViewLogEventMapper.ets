import { LogBean } from '../bean/LogBean';
import { Status } from '../bean/Status';
import { StringWrapper } from '../utils/StringWrapper';

interface WebLogValue { value: Object; }

/** Browser Logs sends a flat event with message/status/date and custom fields. */
export function mapWebViewLogEvent(data: Object, linkRum: boolean): LogBean | null {
  const event = data as Record<string, Object>;
  const message = event['message'];
  if (message === undefined || message === null) return null;
  const text = typeof message === 'object' ? JSON.stringify(message) : String(message);
  if (text.length === 0) return null;
  const date = event['date'];
  // LogBean accepts milliseconds and performs its own nanosecond conversion.
  const time = typeof date === 'number' && Number.isSafeInteger(date) && date > 0 &&
    date <= 9223372036854 ? date : Date.now();
  const log = new LogBean(text, time);
  const status = typeof event['status'] === 'string' ? Status.fromName(event['status'] as string) : null;
  log.setStatus(status === null ? Status.INFO.name : status.name);
  const fields: Record<string, object> = {};
  const rumKeys: string[] = ['application', 'session', 'view', 'action', 'user_action',
    'app_id', 'session_id', 'view_id', 'action_id', 'session_has_replay'];
  for (const key of Object.keys(event)) {
    if (['message', 'status', 'date', 'is_web_view', 'log_source'].includes(key) ||
      (!linkRum && rumKeys.includes(key))) continue;
    const value = event[key];
    if (value !== null && value !== undefined) {
      const wrapped: WebLogValue = { value: typeof value === 'object' ? JSON.stringify(value) : value };
      fields[key] = wrapped;
    }
  }
  const error = event['error'] as Record<string, Object> | undefined;
  if (error !== null && error !== undefined && typeof error === 'object') {
    for (const key of ['message', 'stack']) {
      if (typeof error[key] === 'string') fields[`error_${key}`] = new StringWrapper(error[key] as string);
    }
  }
  log.appendFields(fields);
  const webViewFlag: WebLogValue = { value: true };
  log.addTag('is_web_view', webViewFlag);
  log.addTag('log_source', new StringWrapper('webview'));
  return log;
}
