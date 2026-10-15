/** Shared by ordinary Text, native spans and native control labels. */
export function normalizeReplayFontWeight(value: Object | null | undefined): number | null {
  if (typeof value !== 'string' && typeof value !== 'number') return null;
  const text = String(value).trim().toLowerCase();
  if (text.length === 0) return null;
  const numeric = Number(text);
  if (Number.isFinite(numeric) && numeric >= 100 && numeric <= 900) return Math.round(numeric / 100) * 100;
  const name = text.replace(/^fontweight\./, '').replace(/[\s_-]/g, '');
  switch (name) {
    case 'thin': case 'lighter': return 100;
    case 'extralight': case 'ultralight': return 200;
    case 'light': return 300;
    case 'normal': case 'regular': return 400;
    case 'medium': return 500;
    case 'semibold': case 'demibold': return 600;
    case 'bold': return 700;
    case 'extrabold': case 'ultrabold': return 800;
    case 'bolder': case 'black': case 'heavy': return 900;
    default: return null;
  }
}

function fontObject(value: Object | null | undefined): Record<string, Object> | null {
  if (typeof value === 'string') {
    if (value.length > 65536 || !value.trim().startsWith('{')) return null;
    try { return fontObject(JSON.parse(value) as Object); } catch (_) { return null; }
  }
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, Object> : null;
}

/** Never borrow a weight from a nested child, shadow, or unrelated layout property. */
export function readReplayFontWeight(info: Object | null | undefined): number | null {
  const object = fontObject(info);
  if (object === null) return null;
  const attrs = fontObject(object['$attrs']) ?? object;
  const direct = normalizeReplayFontWeight(attrs['fontWeight']) ?? normalizeReplayFontWeight(attrs['weight']);
  if (direct !== null) return direct;
  const font = fontObject(attrs['font']);
  return normalizeReplayFontWeight(font?.['weight']) ?? normalizeReplayFontWeight(font?.['fontWeight']);
}
