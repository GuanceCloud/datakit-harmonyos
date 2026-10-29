import { describe, it, expect } from '@ohos/hypium';
import { FTSDKConfig, FTRUMConfig, FTLoggerConfig } from '../../main/ets/components/Configs';
import { RemoteConfigBean } from '../../main/ets/components/remote/RemoteConfigBean';
import { normalizeWebViewHosts, isWebViewHostAllowed, resolveAllowedWebViewHosts,
  serializeWebViewHosts } from '../../main/ets/components/web/FTWebViewHostPolicy';
import { mapWebViewLogEvent } from '../../main/ets/components/web/FTWebViewLogEventMapper';

function remote(content: string): RemoteConfigBean {
  return RemoteConfigBean.buildFromConfigJson(`{"content":${content}}`);
}

export default function webViewHostPolicyUnitTest() {
  describe('WebViewHostPolicyUnit', () => {
    it('keeps null and empty array distinct on the JS wire', 0, () => {
      expect(serializeWebViewHosts(null, 'https://example.com')).assertNull();
      expect(serializeWebViewHosts([], 'https://example.com')).assertEqual('[]');
      expect(isWebViewHostAllowed(null, 'about:blank')).assertTrue();
      expect(isWebViewHostAllowed([], 'https://example.com')).assertFalse();
    });

    it('distinguishes unset Base from explicitly configured null', 0, () => {
      const base = FTSDKConfig.builder('http://localhost');
      expect(base.isAllowWebViewHostConfigured()).assertFalse();
      expect(resolveAllowedWebViewHosts(base, ['legacy.test'])!.join(',')).assertEqual('legacy.test');
      base.setAllowWebViewHost(null);
      expect(base.isAllowWebViewHostConfigured()).assertTrue();
      expect(resolveAllowedWebViewHosts(base, [])).assertNull();
    });

    it('resolves remote then explicit Base then legacy RUM including empty and null', 0, () => {
      const base = FTSDKConfig.builder('http://localhost').setAllowWebViewHost(['base.test']);
      base.setRemoteAllowWebViewHostInternal([], true);
      expect(resolveAllowedWebViewHosts(base, ['rum.test'])!.length).assertEqual(0);
      base.setRemoteAllowWebViewHostInternal(null, true);
      expect(resolveAllowedWebViewHosts(base, ['rum.test'])).assertNull();
      base.setRemoteAllowWebViewHostInternal(null, false);
      expect(resolveAllowedWebViewHosts(base, ['rum.test'])!.join(',')).assertEqual('base.test');
      expect(resolveAllowedWebViewHosts(null, ['rum.test'])!.join(',')).assertEqual('rum.test');
    });

    it('normalizes case trailing dot whitespace and duplicate entries', 0, () => {
      expect(normalizeWebViewHosts([' Example.COM. ', 'example.com', 'B.EXAMPLE.COM'])!.join(','))
        .assertEqual('example.com,b.example.com');
      expect(new FTRUMConfig().setAllowWebViewHost(['EXAMPLE.COM.']).getAllowWebViewHost()![0])
        .assertEqual('example.com');
    });

    it('rejects malformed entries without replacing the previous configuration', 0, () => {
      const base = FTSDKConfig.builder('http://localhost').setAllowWebViewHost(['safe.test']);
      for (const entry of ['https://example.com', 'example.com/path', 'example.com:443',
        '*.example.com', '', '.example.com', 'example.com..', 'bad host', 'example.com@evil.test']) {
        let rejected = false;
        try { base.setAllowWebViewHost([entry]); } catch (_) { rejected = true; }
        expect(rejected).assertTrue();
        expect(base.getAllowWebViewHost()![0]).assertEqual('safe.test');
      }
    });

    it('copies input output and resolved snapshots', 0, () => {
      const input = ['example.com'];
      const base = FTSDKConfig.builder('http://localhost').setAllowWebViewHost(input);
      input.push('evil.test');
      const snapshot = resolveAllowedWebViewHosts(base, null)!;
      base.getAllowWebViewHost()!.push('other.test');
      base.setAllowWebViewHost([]);
      expect(snapshot.join(',')).assertEqual('example.com');
      expect(base.getAllowWebViewHost()!.length).assertEqual(0);
    });

    it('matches exact hosts and subdomains with a dot boundary', 0, () => {
      const hosts = ['example.com', 'second.test'];
      for (const address of ['https://example.com/a', 'http://a.b.example.com:8080/',
        'https://EXAMPLE.COM./', 'https://second.test']) {
        expect(isWebViewHostAllowed(hosts, address)).assertTrue();
      }
      for (const address of ['https://badexample.com', 'https://example.com.evil.test',
        'https://unlisted.test', 'about:blank', 'not-a-url', 'file:///test.html']) {
        expect(isWebViewHostAllowed(hosts, address)).assertFalse();
      }
    });

    it('supports literal IPv4 and IPv6 Hosts', 0, () => {
      expect(isWebViewHostAllowed(['127.0.0.1'], 'http://127.0.0.1:8000')).assertTrue();
      const hosts = normalizeWebViewHosts(['[::1]'])!;
      expect(isWebViewHostAllowed(hosts, 'http://[::1]:8000')).assertTrue();
      expect(isWebViewHostAllowed(hosts, 'http://[::2]:8000')).assertFalse();
    });

    it('serializes equivalent trailing-dot aliases for Browser hostname matching', 0, () => {
      expect(serializeWebViewHosts(['example.com'], 'https://sub.example.com./'))
        .assertEqual('["example.com","example.com."]');
      expect(serializeWebViewHosts(['example.com'], 'https://example.com'))
        .assertEqual('["example.com"]');
    });

    it('roundtrips remote absent null empty and nonempty values', 0, () => {
      const absent = remote('{}');
      expect(absent.hasRumAllowWebViewHost()).assertFalse();
      expect(absent.toJsonString().includes('rumAllowWebViewHost')).assertFalse();
      for (const value of ['null', '[]', '["EXAMPLE.COM."]']) {
        const bean = remote(`{"rumAllowWebViewHost":${value}}`);
        expect(bean.hasRumAllowWebViewHost()).assertTrue();
        const restored = RemoteConfigBean.buildFromConfigJson(bean.toJsonString());
        expect(restored.hasRumAllowWebViewHost()).assertTrue();
        expect(JSON.stringify(restored.getRumAllowWebViewHost()))
          .assertEqual(value === '["EXAMPLE.COM."]' ? '["example.com"]' : value);
      }
    });

    it('serializes callback explicit null instead of retaining the old list', 0, () => {
      const bean = remote('{"rumAllowWebViewHost":["old.test"]}');
      bean.setRumAllowWebViewHost(null);
      const restored = RemoteConfigBean.buildFromConfigJson(bean.toJsonString());
      expect(restored.hasRumAllowWebViewHost()).assertTrue();
      expect(restored.getRumAllowWebViewHost()).assertNull();
    });

    it('retains previous valid remote restrictions only for invalid updates', 0, () => {
      const previous = remote('{"rumAllowWebViewHost":[]}');
      for (const value of ['42', '[null]', '["https://bad.test"]', 'false', '{}']) {
        const bean = remote(`{"rumAllowWebViewHost":${value}}`);
        expect(bean.hasRumAllowWebViewHost()).assertFalse();
        bean.preservePreviousValidWebViewHosts(previous);
        expect(bean.hasRumAllowWebViewHost()).assertTrue();
        expect(bean.getRumAllowWebViewHost()!.length).assertEqual(0);
      }
      const removed = remote('{}');
      removed.preservePreviousValidWebViewHosts(previous);
      expect(removed.hasRumAllowWebViewHost()).assertFalse();
    });

    it('accepts the legacy JSON string list but not a scalar host string', 0, () => {
      expect(remote('{"rumAllowWebViewHost":"[\\"example.com\\"]"}').hasRumAllowWebViewHost()).assertTrue();
      expect(remote('{"rumAllowWebViewHost":"example.com"}').hasRumAllowWebViewHost()).assertFalse();
    });

    it('keeps Web Log opt in and independent from custom and console logs', 0, () => {
      const config = new FTLoggerConfig();
      expect(config.isEnableWebViewLog()).assertFalse();
      config.setEnableWebViewLog(true).setEnableCustomLog(false).setEnableConsoleLog(false);
      expect(config.isEnableWebViewLog()).assertTrue();
    });

    it('maps Browser log milliseconds status and custom properties', 0, () => {
      const event = JSON.parse('{"message":"host-log-probe","status":"warning",' +
        '"date":1700000000000,"custom_probe":"kept","error":{"message":"oops","stack":"stack"}}') as Object;
      const log = mapWebViewLogEvent(event, true)!;
      expect(log.getContent()).assertEqual('host-log-probe');
      expect(log.getStatus()).assertEqual('warn');
      expect(log.getTime()).assertEqual(1700000000000);
      const fields = log.getAllFields();
      expect((fields['custom_probe'] as Record<string, Object>)['value'] as string).assertEqual('kept');
      expect((fields['error_message'] as Record<string, Object>)['value'] as string).assertEqual('oops');
    });

    it('drops Browser RUM associations when log linking is disabled', 0, () => {
      const event = JSON.parse('{"message":"log-only","session":{"id":"browser-session"},' +
        '"view_id":"browser-view","custom_probe":true}') as Object;
      const fields = mapWebViewLogEvent(event, false)!.getAllFields();
      expect(Object.keys(fields).includes('session')).assertFalse();
      expect(Object.keys(fields).includes('view_id')).assertFalse();
      expect(Object.keys(fields).includes('custom_probe')).assertTrue();
      expect(mapWebViewLogEvent(new Object(), true)).assertNull();
    });
  });
}
