import { ReplayWireframe } from './SessionReplayProtocol';

/** Protocol DTOs contain only scalars, plain objects and arrays. */
export function replayValuesEqual(left: Object | null | undefined, right: Object | null | undefined): boolean {
  if (left === right) return true;
  if (left === null || right === null || left === undefined || right === undefined ||
    typeof left !== 'object' || typeof right !== 'object') return false;
  if (Array.isArray(left) || Array.isArray(right)) {
    if (!Array.isArray(left) || !Array.isArray(right)) return false;
    const a = left as Array<Object>;
    const b = right as Array<Object>;
    return a.length === b.length && a.every((value: Object, index: number): boolean => replayValuesEqual(value, b[index]));
  }
  const a = left as Record<string, Object>;
  const b = right as Record<string, Object>;
  const keys = Object.keys(a).filter((key: string): boolean => a[key] !== undefined);
  const otherKeys = Object.keys(b).filter((key: string): boolean => b[key] !== undefined);
  return keys.length === otherKeys.length && keys.every((key: string): boolean => replayValuesEqual(a[key], b[key]));
}

export function copyReplayValue(value: Object | null | undefined): Object | null | undefined {
  if (value === null || value === undefined || typeof value !== 'object') return value;
  if (Array.isArray(value)) return (value as Array<Object>).map((item: Object): Object => copyReplayValue(item) as Object);
  const source = value as Record<string, Object>;
  const copy: Record<string, Object> = {};
  for (const key of Object.keys(source)) {
    if (source[key] !== undefined) copy[key] = copyReplayValue(source[key]) as Object;
  }
  return copy;
}

export function copyReplayWireframe(frame: ReplayWireframe): ReplayWireframe {
  return copyReplayValue(frame) as ReplayWireframe;
}
