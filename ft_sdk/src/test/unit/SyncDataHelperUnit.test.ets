import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTLoggerConfig, FTRUMConfig, FTSDKConfig, LogGlobalContextValue } from '../../main/ets/components/Configs';
import { Constants } from '../../main/ets/components/Constants';
import { DataModifierValue, LineDataModifier } from '../../main/ets/components/DataModifier';
import { DataType } from '../../main/ets/components/enum/Enums';
import { SyncDataHelper } from '../../main/ets/components/SyncDataHelper';
import {
  TEST_FIELD_KEY,
  TEST_FIELD_VALUE,
  TEST_MEASUREMENT,
  TEST_TAG_KEY,
  TEST_TAG_VALUE,
  TEST_TIMESTAMP
} from '../helpers/TestConstants';
import { LineProtocolAssert } from '../helpers/LineProtocolAssert';
import { TestReset } from '../helpers/TestReset';

const TEST_FAKE_URL = 'http://www.test.url';

class MaskingLineDataModifier implements LineDataModifier {
  modify(_measurement: string, _data: Map<string, DataModifierValue>): Map<string, DataModifierValue> {
    const result = new Map<string, DataModifierValue>();
    result.set('message', 'masked');
    result.set(Constants.KEY_RUM_USER_ID, 'masked-user');
    return result;
  }
}

export default function syncDataHelperUnitTest() {
  describe('SyncDataHelperUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
    });

    afterEach(() => {
      TestReset.resetP0State();
    });

    it('lineProtocolShouldFormatEscapes', 0, () => {
      const tags: Map<string, string> = new Map();
      tags.set(TEST_TAG_KEY, TEST_TAG_VALUE);
      tags.set('tag with space', 'a,b=c');
      const fields: Map<string, string> = new Map();
      fields.set(TEST_FIELD_KEY, TEST_FIELD_VALUE);
      fields.set('quote', 'a "b"');

      const lineProtocol = SyncDataHelper.convertToLineProtocolLine(
        TEST_MEASUREMENT,
        tags,
        fields,
        TEST_TIMESTAMP,
        false
      );
      const actual = LineProtocolAssert.withoutSdkDataId(lineProtocol);

      expect(actual.includes(`${TEST_MEASUREMENT},${TEST_TAG_KEY}=${TEST_TAG_VALUE}`)).assertTrue();
      expect(actual.includes('tag\\ with\\ space=a\\,b\\=c')).assertTrue();
      expect(actual.includes(`${TEST_FIELD_KEY}="${TEST_FIELD_VALUE}"`)).assertTrue();
      expect(actual.includes('quote="a \\"b\\""')).assertTrue();
      expect(actual.endsWith(`${TEST_TIMESTAMP}`)).assertTrue();
    });

    it('integerCompatShouldControlSuffix', 0, () => {
      const fields: Map<string, string> = new Map();
      fields.set('integer_value', '1');
      fields.set('float_value', '3.14');
      const config = FTSDKConfig.builder(TEST_FAKE_URL).enableDataIntegerCompatible();

      const defaultLine = SyncDataHelper.convertToLineProtocolLine(TEST_MEASUREMENT, new Map(), fields, TEST_TIMESTAMP, false);
      const compatibleLine = SyncDataHelper.convertToLineProtocolLine(
        TEST_MEASUREMENT,
        new Map(),
        fields,
        TEST_TIMESTAMP,
        config.isDataIntegerCompatible()
      );

      expect(defaultLine.includes('integer_value=1i')).assertTrue();
      expect(defaultLine.includes('float_value=3.14')).assertTrue();
      expect(compatibleLine.includes('integer_value=1i')).assertFalse();
      expect(compatibleLine.includes('integer_value=1')).assertTrue();
    });

    it('bodyContentShouldMergeLogContext', 0, () => {
      const helper = new SyncDataHelper();
      const baseConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .addGlobalContext('shared', 'base' as Object)
        .addGlobalContext('base_only', 'base-value' as Object);
      const logConfig = new FTLoggerConfig()
        .addGlobalContext('shared', 'log-static')
        .addGlobalContext('log_only', 'log-value');
      const fields: Map<string, string> = new Map();
      fields.set('message', 'hello');

      helper.initBaseConfig(baseConfig);
      helper.initLogConfig(logConfig);
      helper.appendGlobalContextByKeyValue('shared', 'dynamic-base');
      helper.appendLogGlobalContextByKeyValue('shared', 'dynamic-log');

      const lineProtocol = helper.getBodyContent(TEST_MEASUREMENT, new Map(), fields, TEST_TIMESTAMP, DataType.LOG, 'uuid-log');

      expect(lineProtocol.includes('shared=dynamic-log')).assertTrue();
      expect(lineProtocol.includes('base_only=base-value')).assertTrue();
      expect(lineProtocol.includes('log_only=log-value')).assertTrue();
      expect(lineProtocol.includes('shared=log-static')).assertFalse();
      expect(lineProtocol.includes('shared=base')).assertFalse();
    });

    it('bodyContentShouldMergeLogContextDictionary', 0, () => {
      const helper = new SyncDataHelper();
      const staticContext: Map<string, LogGlobalContextValue> = new Map();
      staticContext.set('dict_string', 'value');
      staticContext.set('dict_number', 42);
      staticContext.set('dict_boolean', true);
      staticContext.set('dict_string_object', new String('wrapped-value'));
      const dynamicContext: Map<string, LogGlobalContextValue> = new Map();
      dynamicContext.set('dynamic_number', 7);
      dynamicContext.set('dynamic_false', false);
      dynamicContext.set('dynamic_empty', '');
      const logConfig = new FTLoggerConfig()
        .addGlobalContext(staticContext)
        .addGlobalContext('legacy_key', 'legacy-value')
        .addGlobalContext('', 'ignored-value');
      const fields: Map<string, string> = new Map();
      fields.set('message', 'dictionary log');

      helper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL));
      helper.initLogConfig(logConfig);
      helper.appendLogGlobalContext(dynamicContext);
      helper.appendLogGlobalContextByKeyValue('dynamic_zero', 0);

      const lineProtocol = helper.getBodyContent(TEST_MEASUREMENT, new Map(), fields, TEST_TIMESTAMP, DataType.LOG, 'uuid-log-dict');

      expect(lineProtocol.includes('dict_string=value')).assertTrue();
      expect(lineProtocol.includes('dict_number=42')).assertTrue();
      expect(lineProtocol.includes('dict_boolean=true')).assertTrue();
      expect(lineProtocol.includes('dict_string_object=wrapped-value')).assertTrue();
      expect(lineProtocol.includes('legacy_key=legacy-value')).assertTrue();
      expect(lineProtocol.includes('dynamic_number=7')).assertTrue();
      expect(lineProtocol.includes('dynamic_false=false')).assertTrue();
      expect(lineProtocol.includes('dynamic_zero=0')).assertTrue();
      expect(lineProtocol.includes('dynamic_empty=')).assertFalse();
      expect(lineProtocol.includes('ignored-value')).assertFalse();
    });

    it('bodyContentShouldLinkRumTags', 0, () => {
      const helper = new SyncDataHelper();
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext('rum_only', 'rum-value' as Object);
      const logConfig = new FTLoggerConfig()
        .setEnableLinkRumData(true)
        .addGlobalContext('log_only', 'log-value');
      const fields: Map<string, string> = new Map();
      fields.set('message', 'linked log');

      helper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL));
      helper.initRUMConfig(rumConfig);
      helper.initLogConfig(logConfig);

      const lineProtocol = helper.getBodyContent(TEST_MEASUREMENT, new Map(), fields, TEST_TIMESTAMP, DataType.LOG, 'uuid-log-rum-link');

      expect(lineProtocol.includes('rum_only=rum-value')).assertTrue();
      expect(lineProtocol.includes('log_only=log-value')).assertTrue();
      expect(lineProtocol.includes('message="linked log"')).assertTrue();
    });

    it('bodyContentShouldAppendWebVersion', 0, () => {
      const helper = new SyncDataHelper();
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext(Constants.KEY_SERVICE, 'native-service' as Object)
        .addGlobalContext(Constants.KEY_SDK_PACKAGE_INFO, '{"agent":"1.0.0"}' as Object);
      const tags: Map<string, string> = new Map();
      tags.set(Constants.KEY_SERVICE, 'browser');
      tags.set(Constants.KEY_SDK_VERSION, '2.0.0');
      const fields: Map<string, string> = new Map();
      fields.set('view_name', 'web');

      helper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL));
      helper.initRUMConfig(rumConfig);

      const lineProtocol = helper.getBodyContent('browser_sdk', tags, fields, TEST_TIMESTAMP, DataType.RUM_WEBVIEW, 'uuid-web');

      expect(lineProtocol.includes('service=browser')).assertTrue();
      expect(lineProtocol.includes('service=native-service')).assertFalse();
      expect(lineProtocol.includes('"agent":"1.0.0"')).assertTrue();
      expect(lineProtocol.includes('"web":"2.0.0"')).assertTrue();
    });

    it('modifierShouldAffectBodyContentOnly', 0, () => {
      const helper = new SyncDataHelper();
      const config = FTSDKConfig.builder(TEST_FAKE_URL).setLineDataModifier(new MaskingLineDataModifier());
      const tags: Map<string, string> = new Map();
      tags.set(Constants.KEY_RUM_USER_ID, 'original-user');
      const fields: Map<string, string> = new Map();
      fields.set('message', 'secret');

      helper.initBaseConfig(config);

      const lineProtocol = helper.getBodyContent(TEST_MEASUREMENT, tags, fields, TEST_TIMESTAMP, DataType.LOG, 'uuid-modifier');

      expect(lineProtocol.includes('message="masked"')).assertTrue();
      expect(lineProtocol.includes(`${Constants.KEY_RUM_USER_ID}=masked-user`)).assertTrue();
      expect(lineProtocol.includes('original-user')).assertFalse();
      expect(lineProtocol.includes('secret')).assertFalse();
    });
  });
}
