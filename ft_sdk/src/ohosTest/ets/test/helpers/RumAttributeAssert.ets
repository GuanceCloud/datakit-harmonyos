import { SyncData } from '../../../../main/ets/components/db/bean/SyncData';

type RumValue = string | number | boolean;

export interface RumAttributePoint {
  measurement: string;
  tags: Map<string, RumValue>;
  fields: Map<string, RumValue>;
  time: string;
}

export interface RumAttributeExpectation {
  measurement: string;
  appId?: string;
  viewName?: string;
  resourceStatus?: number;
  requiredTags?: string[];
  requiredFields?: string[];
}

// Independent contract for SDK-generated native RUM events. Never derive this
// list from the producer or apply it to synthetic DB fixtures / Browser events.
const PUBLIC_TAGS: string[] = [
  'sdk_name', 'sdk_version', 'sdk_pkg_info', 'version', 'env', 'device_uuid',
  'application_uuid', 'service', 'app_id', 'session_type', 'session_id', 'sdk_data_id',
  'os', 'os_version', 'os_version_major', 'device', 'model', 'arch', 'screen_size',
  'network_type', 'userid', 'is_signin'
];
const SAMPLE_FIELDS: string[] = ['session_sample_rate', 'session_on_error_sample_rate'];

/** Attribute assertions shared by ordinary on-device business test cases. */
export class RumAttributeAssert {
  static record(record: SyncData | null, expected: RumAttributeExpectation): RumAttributePoint {
    if (record === null) throw new Error(`RUM ${expected.measurement}: expected a persisted record`);
    const point = RumAttributeAssert.line(record.getDataString(), expected);
    RumAttributeAssert.check(point.tags.get('sdk_data_id') === record.getUuid(), point, 'sdk_data_id differs from DB UUID');
    RumAttributeAssert.check(Number(point.time) === record.getTime(), point, 'timestamp differs from DB metadata');
    return point;
  }

  static uploaded(payload: string, record: SyncData | null, expected: RumAttributeExpectation): RumAttributePoint {
    const stored = RumAttributeAssert.record(record, expected);
    const uuid = record!.getUuid();
    const matches: RumAttributePoint[] = [];
    for (const point of RumAttributeAssert.payload(payload)) {
      const dataId = String(point.tags.get('sdk_data_id') ?? '');
      if (point.measurement === expected.measurement && (dataId === uuid || dataId.endsWith(`.${uuid}`))) {
        RumAttributeAssert.validate(point, expected);
        matches.push(point);
      }
    }
    RumAttributeAssert.check(matches.length === 1, stored,
      `expected one matching uploaded event, found ${matches.length}`);
    const uploaded = matches[0];
    stored.tags.forEach((value: RumValue, key: string) => {
      // The upload Worker adds a package prefix to sdk_data_id for retry deduplication.
      if (key !== 'sdk_data_id') {
        RumAttributeAssert.check(uploaded.tags.get(key) === value, uploaded, `upload changed/missed tag ${key}`);
      }
    });
    stored.fields.forEach((value: RumValue, key: string) => {
      RumAttributeAssert.check(uploaded.fields.get(key) === value, uploaded, `upload changed/missed field ${key}`);
    });
    RumAttributeAssert.check(uploaded.time === stored.time, uploaded, 'upload changed timestamp');
    return uploaded;
  }

  static line(line: string, expected: RumAttributeExpectation): RumAttributePoint {
    const point = RumAttributeAssert.parse(line);
    RumAttributeAssert.validate(point, expected);
    return point;
  }

  static payload(payload: string): RumAttributePoint[] {
    // Stack traces and headers can contain newlines inside quoted fields.
    return RumAttributeAssert.split(payload, '\n', true, true)
      .filter((line) => line.trim().length > 0)
      .map((line) => RumAttributeAssert.parse(line));
  }

  private static validate(point: RumAttributePoint, expected: RumAttributeExpectation): void {
    RumAttributeAssert.check(point.measurement === expected.measurement, point,
      `expected measurement ${expected.measurement}`);
    RumAttributeAssert.requireValues(point, PUBLIC_TAGS, true);
    RumAttributeAssert.numericFields(point, SAMPLE_FIELDS);
    for (const key of SAMPLE_FIELDS) {
      const value = Number(point.fields.get(key));
      RumAttributeAssert.check(value >= 0 && value <= 1, point, `invalid sample rate ${key}`);
    }
    RumAttributeAssert.check(point.tags.get('sdk_name') === 'df_harmonyos_rum_sdk', point, 'invalid sdk_name');
    const packages = JSON.parse(String(point.tags.get('sdk_pkg_info'))) as Record<string, string>;
    RumAttributeAssert.check(packages['agent'] === point.tags.get('sdk_version'), point, 'inconsistent SDK package version');
    RumAttributeAssert.check(['T', 'F'].includes(String(point.tags.get('is_signin'))), point, 'invalid is_signin');
    if (expected.appId !== undefined) {
      RumAttributeAssert.check(point.tags.get('app_id') === expected.appId, point, 'incorrect app_id');
    }
    if (expected.viewName !== undefined) {
      RumAttributeAssert.requireValues(point, ['view_id', 'view_name', 'view_referrer'], true);
      RumAttributeAssert.check(point.tags.get('view_name') === expected.viewName, point, 'incorrect initiating view');
    }
    switch (point.measurement) {
      case 'action':
        RumAttributeAssert.requireValues(point, ['action_id', 'action_name', 'action_type'], true);
        RumAttributeAssert.numericFields(point, ['duration', 'action_error_count', 'action_long_task_count', 'action_resource_count']);
        break;
      case 'view':
        RumAttributeAssert.requireValues(point, ['view_id', 'view_name', 'view_referrer'], true);
        RumAttributeAssert.numericFields(point, ['view_action_count', 'view_error_count', 'view_resource_count',
          'view_long_task_count', 'time_spent', 'view_update_time']);
        RumAttributeAssert.check(typeof point.fields.get('is_active') === 'boolean', point, 'missing/invalid boolean is_active');
        break;
      case 'error':
        RumAttributeAssert.requireValues(point, ['error_type', 'error_source', 'error_situation'], true);
        RumAttributeAssert.requireValues(point, ['error_message'], false);
        if (point.tags.get('error_source') === 'network') {
          RumAttributeAssert.requireValues(point, ['resource_id', 'resource_url', 'resource_status'], true);
        }
        break;
      case 'resource':
        RumAttributeAssert.requireValues(point, ['resource_id', 'resource_url', 'resource_url_host',
          'resource_url_path', 'resource_url_path_group', 'resource_method', 'resource_type'], true);
        RumAttributeAssert.numericFields(point, ['duration']);
        RumAttributeAssert.validateResourceNetworkSnapshot(point);
        // Status 0 explicitly represents no HTTP response and has no HTTP group.
        RumAttributeAssert.requireValues(point, ['resource_status'], true);
        if (expected.resourceStatus !== undefined) {
          RumAttributeAssert.check(point.tags.get('resource_status') === String(expected.resourceStatus), point, 'incorrect resource_status');
          if (expected.resourceStatus > 0) {
            RumAttributeAssert.check(point.tags.get('resource_status_group') === `${Math.floor(expected.resourceStatus / 100)}xx`,
              point, 'incorrect resource_status_group');
          } else {
            RumAttributeAssert.check(!point.tags.has('resource_status_group'), point, 'no response must not have an HTTP status group');
          }
        }
        break;
      case 'long_task':
        RumAttributeAssert.numericFields(point, ['duration']);
        RumAttributeAssert.requireValues(point, ['long_task_stack'], false);
        break;
      default:
        throw new Error(`RUM attribute contract missing for ${point.measurement}`);
    }
    RumAttributeAssert.requireValues(point, expected.requiredTags ?? [], true);
    RumAttributeAssert.requireValues(point, expected.requiredFields ?? [], false);
  }

  private static numericFields(point: RumAttributePoint, keys: string[]): void {
    RumAttributeAssert.requireValues(point, keys, false);
    for (const key of keys) {
      const value = point.fields.get(key);
      RumAttributeAssert.check(typeof value === 'number' && Number.isFinite(value) && value >= 0,
        point, `invalid numeric field ${key}`);
    }
  }

  /**
   * All native Resource producers share the same startResource context. Keep
   * this contract in the common device assertion so manual, RCP, Axios and
   * HTTP-chain tests all verify the final DB row and uploaded Line Protocol.
   */
  private static validateResourceNetworkSnapshot(point: RumAttributePoint): void {
    const available = point.fields.get('network_available');
    RumAttributeAssert.check(typeof available === 'boolean', point,
      'missing/invalid boolean network_available field');
    const optionalKeys = [
      'network_validated', 'network_downlink_kbps', 'network_uplink_kbps', 'network_signal_strength'
    ];
    for (const key of optionalKeys) {
      RumAttributeAssert.check(!point.tags.has(key), point, `${key} is in the wrong tag section`);
    }
    RumAttributeAssert.check(!point.tags.has('network_available'), point,
      'network_available is in the wrong tag section');
    if (!available) {
      for (const key of optionalKeys) {
        RumAttributeAssert.check(!point.fields.has(key), point,
          `${key} must be absent while network_available=false`);
      }
      return;
    }
    const validated = point.fields.get('network_validated');
    if (validated !== undefined) {
      RumAttributeAssert.check(typeof validated === 'boolean', point,
        'network_validated must be boolean when present');
    }
    RumAttributeAssert.validateOptionalNetworkMetric(point, 'network_downlink_kbps', false);
    RumAttributeAssert.validateOptionalNetworkMetric(point, 'network_uplink_kbps', false);
    RumAttributeAssert.validateOptionalNetworkMetric(point, 'network_signal_strength', true);
  }

  private static validateOptionalNetworkMetric(
    point: RumAttributePoint,
    key: string,
    allowsZero: boolean
  ): void {
    const value = point.fields.get(key);
    if (value === undefined) {
      return;
    }
    RumAttributeAssert.check(typeof value === 'number' && Number.isInteger(value) &&
      (allowsZero ? value >= 0 : value > 0), point,
    `${key} must be a ${allowsZero ? 'non-negative' : 'positive'} integer when present`);
  }

  private static requireValues(point: RumAttributePoint, keys: string[], tag: boolean): void {
    const values = tag ? point.tags : point.fields;
    const other = tag ? point.fields : point.tags;
    for (const key of keys) {
      const value = values.get(key);
      RumAttributeAssert.check(values.has(key) && value !== undefined && value !== '' &&
        value !== 'undefined' && value !== 'null' && value !== '[object Object]', point,
        `missing/empty ${tag ? 'tag' : 'field'} ${key}`);
      RumAttributeAssert.check(!other.has(key), point, `${key} is in the wrong tag/field section`);
    }
  }

  private static check(valid: boolean, point: RumAttributePoint, message: string): void {
    if (!valid) throw new Error(`RUM ${point.measurement} [${point.tags.get('sdk_data_id') ?? 'no-id'}]: ${message}`);
  }

  // Test-only parser: handles escaped tag delimiters and quoted field values.
  // Keep the production parser private; tests must not need SDK API changes.
  private static parse(line: string): RumAttributePoint {
    const sections = RumAttributeAssert.split(line.trim(), ' ', true, true);
    if (sections.length !== 3 || !/^\d+$/.test(sections[2]) || Number(sections[2]) <= 0) {
      throw new Error('RUM attribute assertion: invalid Line Protocol sections/timestamp');
    }
    const head = RumAttributeAssert.split(sections[0], ',', false);
    const point: RumAttributePoint = { measurement: RumAttributeAssert.unescape(head[0]),
      tags: new Map<string, RumValue>(), fields: new Map<string, RumValue>(), time: sections[2] };
    for (const pair of head.slice(1)) RumAttributeAssert.readPair(point.tags, pair, false);
    for (const pair of RumAttributeAssert.split(sections[1], ',', true)) {
      RumAttributeAssert.readPair(point.fields, pair, true);
    }
    return point;
  }

  private static readPair(values: Map<string, RumValue>, pair: string, field: boolean): void {
    const parts = RumAttributeAssert.split(pair, '=', false);
    if (parts.length < 2 || parts[0].length === 0) throw new Error('RUM attribute assertion: invalid key/value');
    const key = RumAttributeAssert.unescape(parts[0]);
    const raw = parts.slice(1).join('=');
    let value: RumValue = RumAttributeAssert.unescape(raw);
    if (field) {
      if (raw.startsWith('"') && raw.endsWith('"')) value = RumAttributeAssert.unescape(raw.slice(1, -1));
      else if (raw === 'true' || raw === 'false') value = raw === 'true';
      else if (/^-?\d+i$/.test(raw)) value = Number(raw.slice(0, -1));
      else if (raw.length > 0 && Number.isFinite(Number(raw))) value = Number(raw);
      else throw new Error(`RUM attribute assertion: invalid field ${key}`);
    }
    if (values.has(key)) throw new Error(`RUM attribute assertion: duplicate key ${key}`);
    values.set(key, value);
  }

  // For complete lines/payloads, only the Field section has quoted values.
  // Quotes in measurement names, Tag values and Field keys are ordinary text.
  private static split(text: string, delimiter: string, quotes: boolean, protocol: boolean = false): string[] {
    const parts: string[] = [];
    let start = 0;
    let escaped = false;
    let quoted = false;
    let section = protocol ? 0 : 1;
    let valueStart = false;
    for (let i = 0; i < text.length; i++) {
      const char = text.charAt(i);
      if (escaped) {
        escaped = false;
        valueStart = false;
        continue;
      }
      if (char === '\\') {
        escaped = true;
        valueStart = false;
        continue;
      }
      if (quotes && section === 1 && char === '"' && (quoted || valueStart)) {
        quoted = !quoted;
        valueStart = false;
        continue;
      }
      if (quoted) continue;
      if (char === delimiter) {
        parts.push(text.substring(start, i));
        start = i + 1;
      }
      if (protocol && char === '\n') section = 0;
      else if (protocol && char === ' ') section++;
      valueStart = section === 1 && char === '=';
    }
    if (escaped || quoted) throw new Error('RUM attribute assertion: incomplete escaping/quoted value');
    parts.push(text.substring(start));
    return parts;
  }

  private static unescape(text: string): string {
    return text.replace(/\\(.)/g, '$1');
  }
}
