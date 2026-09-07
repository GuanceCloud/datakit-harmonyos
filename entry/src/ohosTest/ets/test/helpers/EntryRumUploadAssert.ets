import { SyncData } from '@guancecloud/ft_sdk/src/main/ets/components/db/bean/SyncData';
import {
  RumAttributeAssert, RumAttributeExpectation, RumAttributePoint
} from '@guancecloud/ft_sdk/src/ohosTest/ets/test/helpers/RumAttributeAssert';

export interface RumUploadRecord {
  record: SyncData;
  expected: RumAttributeExpectation;
  point: RumAttributePoint;
}

const VIEW_LINKS: string[] = ['session_id', 'view_id', 'view_name', 'view_referrer'];
const ACTION_LINKS: string[] = ['action_id', 'action_name'];
const RESOURCE_LINKS: string[] = ['resource_id', 'resource_url', 'resource_url_host',
  'resource_url_path', 'resource_url_path_group', 'resource_method'];

/** Validate the actual successful upload body, including parent events and counters. */
export class EntryRumUploadAssert {
  static capture(record: SyncData, expected: RumAttributeExpectation): RumUploadRecord {
    return { record, expected, point: RumAttributeAssert.record(record, expected) };
  }

  static uploaded(payload: string, records: RumUploadRecord[], runId: string, networkErrors: number): RumAttributePoint[] {
    const points = records.map((entry) => RumAttributeAssert.uploaded(payload, entry.record, entry.expected));
    EntryRumUploadAssert.relationships(points, runId, networkErrors);
    const resources = points.filter((point) => point.measurement === 'resource');
    const resourceIds = resources.map((point) => EntryRumUploadAssert.tag(point, 'resource_id'));
    const resourceUrls = resources.map((point) => EntryRumUploadAssert.tag(point, 'resource_url'));
    const actual = RumAttributeAssert.payload(payload).filter((point) => point.tags.get('ft_e2e_run') === runId);
    const actualResources = actual.filter((point) => point.measurement === 'resource' &&
      resourceUrls.includes(String(point.tags.get('resource_url'))));
    const actualErrors = actual.filter((point) => point.measurement === 'error' &&
      point.tags.get('error_source') === 'network' &&
      (resourceIds.includes(String(point.tags.get('resource_id'))) ||
        resourceUrls.includes(String(point.tags.get('resource_url')))));
    // Also reject extra events with different UUIDs; selected-row checks alone
    // would miss duplicate Resource/Error records created by two interceptors.
    EntryRumUploadAssert.check(actualResources.length === 4, 'extra/missing Resource in actual upload body');
    EntryRumUploadAssert.check(actualErrors.length === networkErrors, 'extra/missing linked Error in actual upload body');
    return points;
  }

  static relationships(points: RumAttributePoint[], runId: string, networkErrors: number): void {
    EntryRumUploadAssert.check(points.length > 0, 'empty uploaded event graph');
    const views = points.filter((point) => point.measurement === 'view');
    const actions = points.filter((point) => point.measurement === 'action');
    const resources = points.filter((point) => point.measurement === 'resource');
    const errors = points.filter((point) => point.measurement === 'error' && point.tags.get('error_source') === 'network');
    EntryRumUploadAssert.check(resources.length === 4, `expected four resource transports, got ${resources.length}`);
    EntryRumUploadAssert.check(errors.length === networkErrors,
      `expected ${networkErrors} network errors, got ${errors.length}`);
    const resourceIds = resources.map((point) => EntryRumUploadAssert.tag(point, 'resource_id'));
    EntryRumUploadAssert.check(new Set<string>(resourceIds).size === 4, 'resource transports reused a resource_id');

    for (const point of points) {
      EntryRumUploadAssert.sameTags(point, points[0],
        ['app_id', 'session_id', 'session_type', 'device_uuid', 'application_uuid', 'userid', 'is_signin']);
      EntryRumUploadAssert.check(point.tags.get('ft_e2e_run') === runId, 'event belongs to another run');
      EntryRumUploadAssert.check(point.tags.get('custom_key') === 'custom_value', 'missing global custom context');
      EntryRumUploadAssert.check(point.fields.get('session_sample_rate') === 1 &&
        point.fields.get('session_on_error_sample_rate') === 1, 'unexpected sampling attributes');
      if (point.measurement === 'view') {
        EntryRumUploadAssert.check(point.fields.get('is_active') === false, 'expected a closed parent view');
        EntryRumUploadAssert.counters(point, points, 'view_id', 'view');
      } else {
        const view = EntryRumUploadAssert.parent(views, point, 'view_id');
        EntryRumUploadAssert.sameTags(point, view, VIEW_LINKS);
        if (point.measurement === 'action') {
          EntryRumUploadAssert.check(point.tags.get('action_type') === 'click', 'expected UI click action');
          EntryRumUploadAssert.counters(point, points, 'action_id', 'action');
        } else {
          const action = EntryRumUploadAssert.parent(actions, point, 'action_id');
          EntryRumUploadAssert.sameTags(point, action, VIEW_LINKS.concat(ACTION_LINKS));
        }
      }
    }

    for (const resource of resources) {
      const id = EntryRumUploadAssert.tag(resource, 'resource_id');
      const dataId = EntryRumUploadAssert.tag(resource, 'sdk_data_id');
      EntryRumUploadAssert.check(dataId === id || dataId.endsWith(`.${id}`), 'resource_id differs from its record UUID');
      EntryRumUploadAssert.check(Number(resource.fields.get('duration')) > 0, 'resource duration must be positive');
      const requestHeaders = JSON.parse(String(resource.fields.get('request_header'))) as Record<string, string>;
      EntryRumUploadAssert.check(requestHeaders['x-datadog-trace-id'] === resource.tags.get('trace_id'),
        'resource trace_id differs from the outgoing request header');
      EntryRumUploadAssert.check(requestHeaders['x-datadog-parent-id'] === resource.tags.get('span_id'),
        'resource span_id differs from the outgoing request header');
      const matches = errors.filter((error) => error.tags.get('resource_id') === id);
      const status = Number(resource.tags.get('resource_status') ?? '0');
      const failed = status === 0 || status >= 400;
      EntryRumUploadAssert.check(matches.length === (failed ? 1 : 0),
        `resource ${id}: expected ${failed ? 1 : 0} linked errors, got ${matches.length}`);
      if (failed) {
        const error = matches[0];
        EntryRumUploadAssert.sameTags(error, resource, VIEW_LINKS.concat(ACTION_LINKS).concat(RESOURCE_LINKS));
        EntryRumUploadAssert.check(error.tags.get('error_type') === 'network' &&
          error.tags.get('error_situation') === 'run', 'incorrect network error attributes');
        EntryRumUploadAssert.check(error.tags.get('resource_status') === String(status), 'error/resource status mismatch');
        if (status > 0) EntryRumUploadAssert.sameTags(error, resource, ['resource_status_group']);
        EntryRumUploadAssert.check(error.time === resource.time, 'error/resource timestamp mismatch');
        EntryRumUploadAssert.check(String(error.fields.get('error_message')).includes(
          EntryRumUploadAssert.tag(resource, 'resource_url')), 'error message does not identify its resource URL');
      }
    }
    for (const error of errors) EntryRumUploadAssert.parent(resources, error, 'resource_id');
  }

  static tag(point: RumAttributePoint, key: string): string {
    const value = point.tags.get(key);
    EntryRumUploadAssert.check(typeof value === 'string' && value.length > 0,
      `${point.measurement}: missing ${key}`);
    return String(value);
  }

  private static parent(parents: RumAttributePoint[], child: RumAttributePoint, key: string): RumAttributePoint {
    const id = EntryRumUploadAssert.tag(child, key);
    const matches = parents.filter((point) => point.tags.get(key) === id);
    EntryRumUploadAssert.check(matches.length === 1,
      `${child.measurement}: expected one uploaded parent for ${key}=${id}, got ${matches.length}`);
    return matches[0];
  }

  private static sameTags(left: RumAttributePoint, right: RumAttributePoint, keys: string[]): void {
    for (const key of keys) {
      EntryRumUploadAssert.check(EntryRumUploadAssert.tag(left, key) === EntryRumUploadAssert.tag(right, key),
        `${left.measurement}/${right.measurement}: mismatched ${key}`);
    }
  }

  private static counters(parent: RumAttributePoint, points: RumAttributePoint[], key: string, prefix: string): void {
    for (const measurement of ['action', 'resource', 'error', 'long_task']) {
      if (prefix === 'action' && measurement === 'action') continue;
      const count = points.filter((point) => point.measurement === measurement &&
        point.tags.get(key) === parent.tags.get(key)).length;
      EntryRumUploadAssert.check(Number(parent.fields.get(`${prefix}_${measurement}_count`)) >= count,
        `${prefix}: ${measurement} counter is smaller than its uploaded children (${count})`);
    }
  }

  private static check(valid: boolean, message: string): void {
    if (!valid) throw new Error(`RUM upload association: ${message}`);
  }
}
