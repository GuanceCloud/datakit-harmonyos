import { describe, it, expect } from '@ohos/hypium';
import { CharUtils } from '../../main/ets/components/utils/CharUtils';
import { ObjectUtils } from '../../main/ets/components/utils/ObjectUtils';
import { StringUtils } from '../../main/ets/components/utils/StringUtils';
import { DeviceUtils } from '../../main/ets/components/utils/DeviceUtils';
import { Utils } from '../../main/ets/components/utils/Utils';

interface ScoreItem {
  name: string;
  score: number;
  group?: string;
}

function nullableTestValue<T>(value: T | null | undefined): T {
  return value as T;
}

export default function utilsCoreUnitTest() {
  describe('UtilsCoreUnit', () => {
    it('formatHelpersShouldCoverInvalidAndBoundaryInputs', 0, () => {
      expect(Utils.formatDouble(Number.NaN)).assertEqual(0);
      expect(Utils.formatDouble(Number.POSITIVE_INFINITY)).assertEqual(0);
      expect(Utils.formatDouble(1.235, 2)).assertEqual(1.24);

      expect(Utils.formatBytes(0)).assertEqual('0 B');
      expect(Utils.formatBytes(512)).assertEqual('512 B');
      expect(Utils.formatBytes(1536)).assertEqual('1.5 KB');
      expect(Utils.formatBytes(1048576)).assertEqual('1 MB');

      expect(Utils.formatMilliseconds(999)).assertEqual('999ms');
      expect(Utils.formatMilliseconds(1500)).assertEqual('1.50s');
      expect(Utils.formatMilliseconds(61000)).assertEqual('1m 1.00s');
    });

    it('stringAndTypeGuardsShouldCoverTruthyAndFalsyPaths', 0, () => {
      expect(Utils.isEmpty(null)).assertTrue();
      expect(Utils.isEmpty(undefined)).assertTrue();
      expect(Utils.isEmpty('   ')).assertTrue();
      expect(Utils.isNotEmpty('value')).assertTrue();

      expect(Utils.isNumber(1 as Object)).assertTrue();
      expect(Utils.isNumber(Number.NaN as Object)).assertFalse();
      expect(Utils.isNumber(Number.POSITIVE_INFINITY as Object)).assertFalse();
      expect(Utils.isNumber('1' as Object)).assertFalse();
      expect(Utils.isInteger(1 as Object)).assertTrue();
      expect(Utils.isInteger(1.1 as Object)).assertFalse();

      expect(Utils.isValidString('value' as Object)).assertTrue();
      expect(Utils.isValidString('  ' as Object)).assertFalse();
      expect(Utils.isValidObject(new Object())).assertTrue();
      expect(Utils.isValidObject([] as Object)).assertFalse();
      expect(Utils.isValidObject(nullableTestValue<object>(null))).assertFalse();
      expect(Utils.isValidArray([1])).assertTrue();
      expect(Utils.isValidArray([])).assertFalse();
    });

    it('legacyStringObjectAndCharHelpersShouldCoverBlankEmptyAndEqualityBranches', 0, () => {
      const target: Record<string, Object> = new Object() as Record<string, Object>;

      expect(CharUtils.isBlankChar(0x20)).assertTrue();
      expect(CharUtils.isBlankChar(0x41)).assertFalse();
      expect(CharUtils.isAscii('A')).assertTrue();
      expect(CharUtils.isEmoji(0x41)).assertTrue();
      expect(CharUtils.isEmoji(0x0)).assertFalse();

      let asciiThrown = false;
      try {
        CharUtils.isAscii('AB');
      } catch (error) {
        asciiThrown = true;
      }
      expect(asciiThrown).assertTrue();

      expect(ObjectUtils.isString('value')).assertTrue();
      expect(ObjectUtils.isString(1 as Object)).assertFalse();
      expect(ObjectUtils.isNull(null)).assertTrue();
      expect(ObjectUtils.isNull('value' as Object)).assertFalse();
      expect(ObjectUtils.isEmpty(null)).assertTrue();
      expect(ObjectUtils.isEmpty([])).assertTrue();
      expect(ObjectUtils.isEmpty([1])).assertFalse();
      expect(ObjectUtils.isEmpty('')).assertTrue();
      expect(ObjectUtils.isEmpty('value')).assertFalse();
      expect(ObjectUtils.equal('a', 'a')).assertTrue();
      expect(ObjectUtils.notEqual('a', 'b')).assertTrue();
      ObjectUtils.setValue(target, 'name', 'rum' as Object);
      expect(target['name']).assertEqual('rum');

      expect(StringUtils.isBlank(null)).assertTrue();
      expect(StringUtils.isBlank(' \t')).assertTrue();
      expect(StringUtils.isBlank('rum')).assertFalse();
      expect(StringUtils.isNotBlank('rum')).assertTrue();
      expect(StringUtils.startsWith('rum-sdk', 'sdk', 4)).assertTrue();
      expect(StringUtils.isEmpty(null)).assertTrue();
      expect(StringUtils.isEmpty('')).assertTrue();
      expect(StringUtils.isEmpty('undefined', true)).assertTrue();
      expect(StringUtils.isEmpty('value')).assertFalse();
      expect(StringUtils.isNotEmpty('value')).assertTrue();
      expect(StringUtils.toString(null, 'fallback')).assertEqual('fallback');
      expect(StringUtils.toString(123 as Object)).assertEqual('123');
      expect(StringUtils.replaceAll('a.b.a', '\\.', '-')).assertEqual('a-b-a');
      expect(StringUtils.unit8ArrayToStr(new Uint8Array())).assertEqual('');
    });

    it('cloneAndObjectHelpersShouldCoverPrimitiveDateArrayAndJsonBranches', 0, () => {
      const date = new Date(1700000000000);
      const clonedDate = Utils.deepClone(date);
      const clonedArray = Utils.deepClone([1, 2, 3]);
      const objectValue: Record<string, Object> = new Object() as Record<string, Object>;
      objectValue['name'] = 'rum' as Object;
      objectValue['count'] = 1 as Object;

      expect(Utils.deepClone(7)).assertEqual(7);
      expect(clonedDate === date).assertFalse();
      expect(clonedDate.getTime()).assertEqual(date.getTime());
      expect(clonedArray.length).assertEqual(3);
      expect(Utils.getObjectKeys(objectValue).length).assertEqual(0);
      expect(Utils.getObjectValues(objectValue).length).assertEqual(2);
      expect(Utils.isEmptyObject(nullableTestValue<object>(undefined))).assertTrue();
      expect(Utils.isEmptyObject(objectValue)).assertTrue();

      const circular: Record<string, Object> = new Object() as Record<string, Object>;
      circular['self'] = circular as Object;
      expect(Utils.toJsonString(objectValue).includes('"name":"rum"')).assertTrue();
      expect(Utils.toJsonString(objectValue, true).includes('\n')).assertTrue();
      expect(Utils.toJsonString(circular)).assertEqual('{}');

      const parsed = Utils.fromJsonString<Record<string, Object>>('{"name":"rum"}');
      expect(parsed !== null).assertTrue();
      if (parsed !== null) {
        expect(parsed['name']).assertEqual('rum');
      }
      expect(Utils.fromJsonString<Record<string, Object>>('{')).assertEqual(null);
      expect(Utils.isValidJson('{"ok":true}')).assertTrue();
      expect(Utils.isValidJson('{')).assertFalse();
    });

    it('nestedObjectHelpersShouldSetGetAndFallbackSafely', 0, () => {
      const nested: Record<string, Object> = new Object() as Record<string, Object>;

      expect(Utils.getNestedValue(nested, '', 'fallback' as Object)).assertEqual('fallback');
      expect(Utils.getNestedValue(nullableTestValue<object>(null), 'a.b', 'fallback' as Object)).assertEqual('fallback');
      expect(Utils.setNestedValue(nested, '', 'ignored' as Object)).assertFalse();
      expect(Utils.setNestedValue(nullableTestValue<object>(null), 'a.b', 'ignored' as Object)).assertFalse();
      expect(Utils.setNestedValue(nested, 'user.profile.name', 'datakit' as Object)).assertTrue();
      expect(Utils.getNestedValue(nested, 'user.profile.name')).assertEqual('datakit');
      expect(Utils.getNestedValue(nested, 'user.profile.missing', 'fallback' as Object)).assertEqual('fallback');
      expect(Utils.hasKey(nested, 'user')).assertTrue();
      expect(Utils.hasKey(nested, 'missing')).assertFalse();
      expect(Utils.safeGet<string>(nested, 'missing', 'fallback')).assertEqual('fallback');
    });

    it('arrayHelpersShouldCoverEmptyRegularKeyedAndGroupedPaths', 0, () => {
      expect(Utils.uniqueArray<number>([]).length).assertEqual(0);
      expect(Utils.uniqueArray([1, 1, 2]).join(',')).assertEqual('1,2');

      const asc = Utils.sortArray([3, 1, 2]);
      const desc = Utils.sortArray([3, 1, 2], undefined, 'desc');
      expect(asc.join(',')).assertEqual('1,2,3');
      expect(desc.join(',')).assertEqual('3,2,1');

      const items: ScoreItem[] = [
        { name: 'a', score: 2, group: 'core' },
        { name: 'b', score: 3, group: 'core' },
        { name: 'c', score: 1 }
      ];
      const sortedByScore = Utils.sortArray<ScoreItem>(items, 'score', 'desc');
      const grouped = Utils.groupArray<ScoreItem>(items, 'group');
      expect(sortedByScore[0].name).assertEqual('b');
      expect(grouped['core'].length).assertEqual(2);
      expect(grouped['unknown'].length).assertEqual(1);
      expect(Utils.groupArray<ScoreItem>([], 'group')['core']).assertEqual(undefined);

      expect(Utils.filterArray([1, 2, 3], (item: number) => item > 1).join(',')).assertEqual('2,3');
      expect(Utils.filterArray<number>([], (item: number) => item > 1).length).assertEqual(0);
      expect(Utils.mapArray([1, 2], (item: number) => item * 2).join(',')).assertEqual('2,4');
      expect(Utils.mapArray<number, number>([], (item: number) => item * 2).length).assertEqual(0);
      expect(Utils.findInArray([1, 2, 3], (item: number) => item === 2)).assertEqual(2);
      expect(Utils.findInArray<number>([], (item: number) => item === 2)).assertEqual(undefined);
      expect(Utils.arrayContains([1, 2], 2)).assertTrue();
      expect(Utils.arrayContains<number>([], 2)).assertFalse();
      expect(Utils.getFirstElement([1, 2])).assertEqual(1);
      expect(Utils.getFirstElement<number>([])).assertEqual(undefined);
      expect(Utils.getLastElement([1, 2])).assertEqual(2);
      expect(Utils.getLastElement<number>([])).assertEqual(undefined);
      expect(Utils.chunkArray([1, 2, 3], 2).length).assertEqual(2);
      expect(Utils.chunkArray([1, 2, 3], 0).length).assertEqual(0);
    });

    it('timeRandomAndRetryHelpersShouldCoverSuccessAndFailurePaths', 0, async () => {
      const timestamp = new Date(2024, 0, 2, 3, 4, 5).getTime();
      const randomNumber = Utils.randomNumber(3, 5);
      const randomFloat = Utils.randomFloat(1, 2, 1);
      let retryCount = 0;

      expect(Utils.formatTimestamp(timestamp)).assertEqual('2024-01-02 03:04:05');
      expect(Utils.formatTimestamp(timestamp, 'YYYY/MM/DD')).assertEqual('2024/01/02');
      expect(Utils.getTimeDifference(10, 3)).assertEqual(7);
      expect(randomNumber >= 3 && randomNumber <= 5).assertTrue();
      expect(randomFloat >= 1 && randomFloat <= 2).assertTrue();
      expect(Utils.generateRandomId(0)).assertEqual('');
      expect(Utils.generateRandomId(6).length).assertEqual(6);
      expect(Utils.millisToMicros(2)).assertEqual(2000);
      expect(Utils.microsToMillis(2500)).assertEqual(2);
      expect(Utils.microsToNanos(3)).assertEqual(3000);
      expect(Utils.getSystemInfo().language).assertEqual('zh-CN');
      expect(Utils.getMemoryInfo().message.length > 0).assertTrue();
      expect(Utils.getPerformanceInfo().message.length > 0).assertTrue();

      const retriedValue = await Utils.retry<string>(async () => {
        retryCount++;
        if (retryCount === 1) {
          throw new Error('first');
        }
        return 'ok';
      }, 1, 0);
      expect(retriedValue).assertEqual('ok');
      expect(retryCount).assertEqual(2);

      let retryThrown = false;
      try {
        await Utils.retry<string>(async () => {
          throw new Error('always');
        }, 0, 0);
      } catch (error) {
        retryThrown = true;
        expect(String(error).includes('Retry failed after 0 attempts')).assertTrue();
      }
      expect(retryThrown).assertTrue();
    });

    it('deviceUtilsBatteryInfoShouldSettleWithFallbackValues', 0, async () => {
      const batteryInfo = await DeviceUtils.getBatteryInfo();

      expect(batteryInfo.level).assertEqual(0);
      expect(batteryInfo.charging).assertFalse();
      expect(batteryInfo.chargingTime).assertEqual(0);
      expect(batteryInfo.dischargingTime).assertEqual(0);
    });
  });
}
