import hilog from '@ohos.hilog';

const DOMAIN = 0x0000;
const TAG_PREFIX = 'FT-Demo-';
const MAX_TAG_LENGTH = 32;
type LogArg = string | number | boolean | object | Error | null | undefined;

function normalizeTag(tag: string): string {
  const trimmedTag = tag.trim().length > 0 ? tag.trim() : 'Unknown';
  const availableLength = MAX_TAG_LENGTH - TAG_PREFIX.length;
  if (availableLength <= 0) {
    return TAG_PREFIX.substring(0, MAX_TAG_LENGTH);
  }

  const normalizedTag = trimmedTag.length > availableLength
    ? trimmedTag.substring(0, availableLength)
    : trimmedTag;
  return `${TAG_PREFIX}${normalizedTag}`;
}

function formatValue(value: LogArg): string {
  if (value instanceof Error) {
    return value.stack ? `${value.message}\n${value.stack}` : value.message;
  }

  if (typeof value === 'string') {
    return value;
  }

  if (typeof value === 'object' && value !== null) {
    try {
      return JSON.stringify(value);
    } catch (error) {
      return String(value);
    }
  }

  return String(value);
}

function formatMessage(args: LogArg[]): string {
  if (args.length === 0) {
    return '';
  }

  return args.map((arg: LogArg) => formatValue(arg)).join(' ');
}

export class DemoLogger {
  static d(tag: string, ...args: LogArg[]): void {
    hilog.debug(DOMAIN, normalizeTag(tag), '%{public}s', formatMessage(args));
  }

  static i(tag: string, ...args: LogArg[]): void {
    hilog.info(DOMAIN, normalizeTag(tag), '%{public}s', formatMessage(args));
  }

  static w(tag: string, ...args: LogArg[]): void {
    hilog.warn(DOMAIN, normalizeTag(tag), '%{public}s', formatMessage(args));
  }

  static e(tag: string, ...args: LogArg[]): void {
    hilog.error(DOMAIN, normalizeTag(tag), '%{public}s', formatMessage(args));
  }
}
