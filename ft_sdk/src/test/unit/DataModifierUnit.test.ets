import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { Constants } from '../../main/ets/components/Constants';
import { SyncDataHelper } from '../../main/ets/components/SyncDataHelper';
import { FTSDKConfig } from '../../main/ets/components/Configs';
import { DataType } from '../../main/ets/components/enum/Enums';
import { LineDataModifier } from '../../main/ets/components/DataModifier';
import { FakeDataModifier, FakeLineDataModifier, TEST_MASK_VALUE } from '../helpers/FakeDataModifier';
import { LineProtocolAssert } from '../helpers/LineProtocolAssert';
import { TestReset } from '../helpers/TestReset';

const TEST_FAKE_URL = 'http://www.test.url';

class EmptyLineDataModifier implements LineDataModifier {
  modify(_measurement: string, _tags: Map<string, string>, _fields: Map<string, string>): Map<string, string> {
    return new Map();
  }
}

class PriorityLineDataModifier implements LineDataModifier {
  modify(_measurement: string, tags: Map<string, string>, fields: Map<string, string>): Map<string, string> {
    const result: Map<string, string> = new Map();
    tags.forEach((value: string, key: string) => result.set(key, value));
    fields.forEach((value: string, key: string) => result.set(key, value));

    result.set('same_key', 'line_from_fields');
    result.set('same_key', 'line_from_modifier');
    result.set(Constants.KEY_RUM_USER_ID, TEST_MASK_VALUE);
    return result;
  }
}

class ChainedMapLineDataModifier implements LineDataModifier {
  modify(_measurement: string, tags: Map<string, string>, fields: Map<string, string>): Map<string, string> {
    const result: Map<string, string> = new Map();
    tags.forEach((value: string, key: string) => result.set(key, value));
    fields.forEach((value: string, key: string) => result.set(key, value));

    result.set('stage_one', '1');
    result.set('stage_two', '2');
    result.set('stage_one', '3');
    result.delete('stage_two');
    result.set('stage_two', '4');

    result.set('sequence', 'a');
    result.set('sequence', 'b');
    return result;
  }
}

export default function dataModifierUnitTest() {
  describe('DataModifierUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
    });

    afterEach(() => {
      TestReset.resetP0State();
    });

    it('dataModifierShouldMaskOnlyTargetKey', 0, () => {
      const modifier = new FakeDataModifier();

      expect(modifier.modify(Constants.KEY_DEVICE_UUID, 'original-uuid')).assertEqual(TEST_MASK_VALUE);
      expect(modifier.modify('service_name', 'my_service')).assertEqual('my_service');
      expect(modifier.modify('env', 'prod')).assertEqual('prod');
    });

    it('lineDataModifierShouldMergeTagsFieldsAndMaskUserId', 0, () => {
      const tags: Map<string, string> = new Map();
      tags.set('tag1', 'value1');
      tags.set(Constants.KEY_RUM_USER_ID, 'original-user-id');

      const fields: Map<string, string> = new Map();
      fields.set('field1', 'fieldValue1');

      const result = new FakeLineDataModifier().modify('test_measurement', tags, fields);

      expect(result.size).assertEqual(3);
      expect(result.get('tag1')).assertEqual('value1');
      expect(result.get('field1')).assertEqual('fieldValue1');
      expect(result.get(Constants.KEY_RUM_USER_ID)).assertEqual(TEST_MASK_VALUE);
    });

    it('configShouldStoreModifierInstancesForChaining', 0, () => {
      const dataModifier = new FakeDataModifier();
      const lineDataModifier = new FakeLineDataModifier();
      const config = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDataModifier(dataModifier)
        .setLineDataModifier(lineDataModifier)
        .setDebug(true)
        .setServiceName('test_service');

      expect(config.getDataModifier() === dataModifier).assertTrue();
      expect(config.getLineDataModifier() === lineDataModifier).assertTrue();
      expect(config.isDebugMode()).assertTrue();
      expect(config.getServiceName()).assertEqual('test_service');
    });

    it('lineProtocolShouldContainModifiedUserId', 0, () => {
      const tags: Map<string, string> = new Map();
      tags.set(Constants.KEY_DEVICE_UUID, 'test-uuid');
      tags.set(Constants.KEY_RUM_USER_ID, 'test-user-id');
      tags.set('env', 'prod');

      const fields: Map<string, string> = new Map();
      fields.set('action_name', 'test_action');

      const modifiedData = new FakeLineDataModifier().modify('rum_app', tags, fields);
      const modifiedTags: Map<string, string> = new Map();
      const modifiedFields: Map<string, string> = new Map();

      modifiedData.forEach((value: string, key: string) => {
        if (key === 'action_name') {
          modifiedFields.set(key, value);
        } else {
          modifiedTags.set(key, value);
        }
      });

      const lineProtocol = SyncDataHelper.convertToLineProtocolLine(
        'rum_app',
        modifiedTags,
        modifiedFields,
        1234567890,
        false
      );

      expect(lineProtocol.includes('rum_app')).assertTrue();
      expect(lineProtocol.includes('env=prod')).assertTrue();
      expect(lineProtocol.includes('action_name="test_action"')).assertTrue();
      expect(lineProtocol.includes(Constants.KEY_RUM_USER_ID + '=' + TEST_MASK_VALUE)).assertTrue();
      expect(lineProtocol.includes('test-user-id')).assertFalse();
    });

    it('when line modifier returns empty map should only output required sdk fields', 0, () => {
      const helper = new SyncDataHelper();
      const config = FTSDKConfig.builder(TEST_FAKE_URL).setLineDataModifier(new EmptyLineDataModifier());

      helper.initBaseConfig(config);
      const tags: Map<string, string> = new Map();
      tags.set('keep_tag', 'should_not_survive');
      tags.set('env', 'prod');
      const fields: Map<string, string> = new Map();
      fields.set('message', 'hello');
      fields.set('count', '1');

      const lineProtocol = helper.getBodyContent(
        'rum_app',
        tags,
        fields,
        1234567890,
        DataType.LOG,
        'uuid-log-empty'
      );

      expect(lineProtocol.includes('keep_tag')).assertFalse();
      expect(lineProtocol.includes('message')).assertFalse();
      expect(lineProtocol.includes('count')).assertFalse();
      expect(lineProtocol.includes('env=prod')).assertFalse();
      expect(lineProtocol.startsWith('rum_app ')).assertTrue();
    });

    it('when duplicate keys conflict should keep modifier-determined overwrite order', 0, () => {
      const helper = new SyncDataHelper();
      const config = FTSDKConfig.builder(TEST_FAKE_URL).setLineDataModifier(new PriorityLineDataModifier());

      helper.initBaseConfig(config);
      const tags: Map<string, string> = new Map();
      tags.set('same_key', 'from_tag');
      tags.set('first_only', 'tag');

      const fields: Map<string, string> = new Map();
      fields.set('same_key', 'from_field');
      fields.set('second_only', 'field');

      const lineProtocol = helper.getBodyContent(
        'rum_app',
        tags,
        fields,
        1234567890,
        DataType.LOG,
        'uuid-log-priority'
      );

      expect(lineProtocol.includes('same_key=line_from_modifier')).assertTrue();
      expect(lineProtocol.includes('first_only=tag')).assertTrue();
      expect(lineProtocol.includes('second_only="field"')).assertTrue();
      expect(lineProtocol.includes('from_tag')).assertFalse();
      expect(lineProtocol.includes('from_field')).assertFalse();
      expect(lineProtocol.includes(Constants.KEY_RUM_USER_ID)).assertTrue();
    });

    it('when modifier chain has chained map mutations should remain deterministic after convertToLineProtocolLine', 0, () => {
      const helper = new SyncDataHelper();
      const config = FTSDKConfig.builder(TEST_FAKE_URL).setLineDataModifier(new ChainedMapLineDataModifier());
      helper.initBaseConfig(config);

      const tags: Map<string, string> = new Map();
      tags.set('origin', 'tag');
      const fields: Map<string, string> = new Map();
      fields.set('value', '1');

      const first = helper.getBodyContent(
        'rum_app',
        new Map(tags),
        new Map(fields),
        1234567890,
        DataType.LOG,
        'uuid-log-chain-1'
      );

      const second = helper.getBodyContent(
        'rum_app',
        new Map(tags),
        new Map(fields),
        1234567890,
        DataType.LOG,
        'uuid-log-chain-2'
      );

      expect(LineProtocolAssert.withoutSdkDataId(first)).assertEqual(LineProtocolAssert.withoutSdkDataId(second));
      expect(first.includes('stage_one=3')).assertTrue();
      expect(first.includes('stage_two=4')).assertTrue();
      expect(first.includes('sequence="b"')).assertTrue();
      expect(first.includes('origin=tag')).assertTrue();
    });
  });
}
