import url from '@ohos.url';

/** Internal config surface; keeps Host resolution independent of RUM and Log. */
export interface FTWebViewHostConfiguration {
  isAllowWebViewHostConfigured(): boolean;
  getAllowWebViewHost(): string[] | null;
  hasRemoteAllowWebViewHostInternal(): boolean;
  getRemoteAllowWebViewHostInternal(): string[] | null;
}

/** Host names only. URLs, ports, wildcard patterns and empty entries are rejected. */
export function normalizeWebViewHost(value: string): string {
  const host = value.trim().toLowerCase().replace(/\.$/, '');
  if (host.length === 0 || host.length > 253 || /[\s\/@?#]/.test(host)) {
    throw new Error('WebView allow-list entries must be non-empty Host names');
  }
  if (host.startsWith('[') && host.endsWith(']')) {
    try {
      const parsed = new url.URL(`http://${host}/`);
      if (parsed.hostname.indexOf(':') >= 0) return parsed.hostname.toLowerCase();
    } catch (_) {}
    throw new Error('Invalid IPv6 WebView Host');
  }
  if (host.indexOf(':') >= 0 || !host.split('.').every((label: string): boolean =>
    /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) {
    throw new Error('WebView allow-list accepts Host names without scheme, path or port');
  }
  return host;
}

export function normalizeWebViewHosts(hosts: string[] | null): string[] | null {
  if (hosts === null) return null;
  if (!Array.isArray(hosts)) throw new Error('WebView Host policy must be null or an array');
  const normalized: string[] = [];
  for (const host of hosts) {
    if (typeof host !== 'string') throw new Error('WebView Host entries must be strings');
    const value = normalizeWebViewHost(host);
    if (!normalized.includes(value)) normalized.push(value);
  }
  return normalized;
}

export function resolveAllowedWebViewHosts(
  base: FTWebViewHostConfiguration | null,
  legacy: string[] | null
): string[] | null {
  if (base !== null) {
    if (base.hasRemoteAllowWebViewHostInternal()) return base.getRemoteAllowWebViewHostInternal();
    if (base.isAllowWebViewHostConfigured()) return base.getAllowWebViewHost();
  }
  return legacy === null ? null : legacy.slice();
}

export function getWebViewDocumentHost(documentUrl: string): string {
  try {
    return normalizeWebViewHost(new url.URL(documentUrl).hostname);
  } catch (_) {
    return '';
  }
}

export function isWebViewHostAllowed(hosts: string[] | null, documentUrl: string): boolean {
  if (hosts === null) return true;
  if (hosts.length === 0) return false;
  const host = getWebViewDocumentHost(documentUrl);
  if (host.length === 0) return false;
  return hosts.some((allowed: string): boolean => host === allowed || host.endsWith(`.${allowed}`));
}

/** Browser SDK compares raw hostname strings; preserve equivalent DNS trailing dots. */
export function serializeWebViewHosts(hosts: string[] | null, documentUrl: string): string | null {
  if (hosts === null) return null;
  // HarmonyOS URL.hostname removes a DNS trailing dot. Browser location.hostname
  // retains it, so inspect the controller URL's authority before normalization.
  const authority = documentUrl.match(/^[a-z][a-z0-9+.-]*:\/\/(?:[^/?#]*@)?([^/?#]+)/i);
  const trailingDot = authority !== null && authority[1].replace(/:\d+$/, '').endsWith('.');
  const wire = hosts.slice();
  if (trailingDot) {
    for (const host of hosts) {
      if (host.indexOf(':') < 0) wire.push(`${host}.`);
    }
  }
  return JSON.stringify(wire);
}

/** Holds only the installed base configuration; never retains a WebView or UI context. */
export class FTWebViewHostPolicy {
  private static base: FTWebViewHostConfiguration | null = null;

  public static install(base: FTWebViewHostConfiguration | null): void {
    FTWebViewHostPolicy.base = base;
  }

  public static resolve(legacy: string[] | null): string[] | null {
    return resolveAllowedWebViewHosts(FTWebViewHostPolicy.base, legacy);
  }
}
