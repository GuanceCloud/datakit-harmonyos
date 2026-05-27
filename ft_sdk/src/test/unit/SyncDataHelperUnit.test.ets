import { describe, beforeEach, afterEach, it, expect } from '@ohos/hypium';
import { FTLoggerConfig, FTRUMConfig, FTSDKConfig } from '../../main/ets/components/Configs';
import { Constants } from '../../main/ets/components/Constants';
import { DataModifier, LineDataModifier } from '../../main/ets/components/DataModifier';
import { DataType } from '../../main/ets/components/enum/Enums';
import { FTRUMInnerManager } from '../../main/ets/components/rum/FTRUMInnerManager';
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

function nullableTestValue<T>(value: T | null): T {
  return value as T;
}

interface ParsedLineProtocol {
  tags: Map<string, string>;
  fields: Map<string, string>;
}

class ValueFieldWrapper {
  value: string;

  constructor(value: string) {
    this.value = value;
  }
}

class GetterFieldWrapper {
  getValue(): string {
    return 'getter value';
  }
}

class ThrowingGetterFieldWrapper {
  getValue(): string {
    throw new Error('getter failed');
  }

  toString(): string {
    return 'fallback value';
  }
}

class ThrowingGetterAndToStringFieldWrapper {
  getValue(): string {
    throw new Error('getter failed');
  }

  toString(): string {
    throw new Error('toString failed');
  }
}

class JsonStringFieldWrapper {
  toString(): string {
    return '{"value":"json value"}';
  }
}

class QuotedJsonStringFieldWrapper {
  toString(): string {
    return '{"value":"\\"quoted object value\\""}';
  }
}

class BadJsonStringFieldWrapper {
  toString(): string {
    return '{"value":';
  }
}

class JsonNoValueStringFieldWrapper {
  toString(): string {
    return '{"other":"json object"}';
  }
}

class BadClosedJsonStringFieldWrapper {
  toString(): string {
    return '{"value":}';
  }
}

class PlainStringFieldWrapper {
  toString(): string {
    return 'plain object value';
  }
}

class ThrowingToStringFieldWrapper {
  fallback: string = 'json fallback value';

  toString(): string {
    throw new Error('toString failed');
  }
}

class ThrowingSdkPackageInfoDataModifier implements DataModifier {
  modify(key: string, value: string): string {
    if (key === Constants.KEY_SDK_PACKAGE_INFO) {
      throw new Error('sdk package info modify failed');
    }
    return value;
  }
}

class QuoteSdkPackageInfoLineDataModifier implements LineDataModifier {
  modify(_measurement: string, tags: Map<string, string>, fields: Map<string, string>): Map<string, string> {
    const result = new Map<string, string>();
    tags.forEach((value: string, key: string) => {
      if (key === Constants.KEY_SDK_PACKAGE_INFO) {
        result.set(key, `"${value}"`);
      } else {
        result.set(key, value);
      }
    });
    fields.forEach((value: string, key: string) => result.set(key, value));
    return result;
  }
}

class RewriteSdkPackageInfoLineDataModifier implements LineDataModifier {
  replacement: Object;

  constructor(replacement: Object) {
    this.replacement = replacement;
  }

  modify(_measurement: string, tags: Map<string, string>, fields: Map<string, string>): Map<string, string> {
    const result = new Map<string, string>();
    tags.forEach((value: string, key: string) => {
      if (key === Constants.KEY_SDK_PACKAGE_INFO) {
        result.set(key, this.replacement as string);
      } else {
        result.set(key, value);
      }
    });
    fields.forEach((value: string, key: string) => result.set(key, value));
    return result;
  }
}

function parseLineProtocol(lineProtocol: string): ParsedLineProtocol {
  const tags = new Map<string, string>();
  const fields = new Map<string, string>();
  const trimmed = lineProtocol.trim();
  const firstSpace = trimmed.indexOf(' ');

  let tagSection = trimmed;
  let fieldSection = '';

  if (firstSpace >= 0) {
    const headerPart = trimmed.substring(0, firstSpace);
    const fullFieldPart = trimmed.substring(firstSpace + 1).trim();
    const secondSpace = fullFieldPart.indexOf(' ');

    const commaIndex = headerPart.indexOf(',');
    if (commaIndex >= 0) {
      tagSection = headerPart.substring(commaIndex + 1);
    } else {
      tagSection = '';
    }

    if (secondSpace >= 0) {
      fieldSection = fullFieldPart.substring(0, secondSpace);
    } else {
      fieldSection = fullFieldPart;
    }
  } else {
    fieldSection = '';
    tagSection = '';
  }

  const tagEntries = tagSection.length > 0 ? tagSection.split(',') : [];
  for (let i = 0; i < tagEntries.length; i++) {
    const entry = tagEntries[i];
    const equalsIndex = entry.indexOf('=');
    if (equalsIndex >= 0) {
      const key = entry.substring(0, equalsIndex);
      const value = entry.substring(equalsIndex + 1);
      tags.set(key, value);
    }
  }

  const fieldEntries = fieldSection.length > 0 ? fieldSection.split(',') : [];
  for (let i = 0; i < fieldEntries.length; i++) {
    const entry = fieldEntries[i];
    const equalsIndex = entry.indexOf('=');
    if (equalsIndex >= 0) {
      const key = entry.substring(0, equalsIndex);
      let value = entry.substring(equalsIndex + 1);
      const isQuotedValue = value.startsWith('"') && value.endsWith('"');
      if (isQuotedValue) {
        value = value.substring(1, value.length - 1);
      } else if (/^-?\d+i$/.test(value)) {
        value = value.substring(0, value.length - 1);
      }
      fields.set(key, value);
    }
  }

  return { tags, fields };
}

export default function syncDataHelperUnitTest() {
  describe('SyncDataHelperUnit', () => {
    beforeEach(() => {
      TestReset.resetP0State();
    });

    afterEach(() => {
      TestReset.resetP0State();
    });

    it('lineProtocolShouldFormatBasicTagsAndFields', 0, () => {
      const tags: Map<string, string> = new Map();
      tags.set(TEST_TAG_KEY, TEST_TAG_VALUE);

      const fields: Map<string, string> = new Map();
      fields.set(TEST_FIELD_KEY, TEST_FIELD_VALUE);

      const lineProtocol = SyncDataHelper.convertToLineProtocolLine(
        TEST_MEASUREMENT,
        tags,
        fields,
        TEST_TIMESTAMP,
        false
      );
      const actual = LineProtocolAssert.withoutSdkDataId(lineProtocol);

      expect(actual).assertEqual(
        `${TEST_MEASUREMENT},${TEST_TAG_KEY}=${TEST_TAG_VALUE} ${TEST_FIELD_KEY}="${TEST_FIELD_VALUE}" ${TEST_TIMESTAMP}`
      );
    });

    it('lineProtocolShouldSkipEmptyFields', 0, () => {
      const tags: Map<string, string> = new Map();
      const fields: Map<string, string> = new Map();
      fields.set(TEST_FIELD_KEY, '');

      const lineProtocol = SyncDataHelper.convertToLineProtocolLine(
        TEST_MEASUREMENT,
        tags,
        fields,
        TEST_TIMESTAMP,
        false
      );
      const actual = LineProtocolAssert.withoutSdkDataId(lineProtocol);

      expect(actual).assertEqual(`${TEST_MEASUREMENT} ${TEST_TIMESTAMP}`);
    });

    it('translateMethodsShouldEscapeLineProtocolCharacters', 0, () => {
      expect(SyncDataHelper.translateMeasurements('a b,c')).assertEqual('a\\ b\\,c');
      expect(SyncDataHelper.translateTagKeyValue('a b=c')).assertEqual('a\\ b\\=c');
      expect(SyncDataHelper.translateFieldValue('a "b"')).assertEqual('"a \\"b\\""');
    });

    it('integerCompatibleShouldControlIntegerSuffix', 0, () => {
      const fields: Map<string, string> = new Map();
      fields.set('integer_value', '1');
      fields.set('float_value', '3.14');

      const defaultLine = SyncDataHelper.convertToLineProtocolLine(
        TEST_MEASUREMENT,
        new Map(),
        fields,
        TEST_TIMESTAMP,
        false
      );
      expect(defaultLine.includes('integer_value=1i')).assertTrue();
      expect(defaultLine.includes('float_value=3.14i')).assertFalse();
      expect(defaultLine.includes('float_value=3.14')).assertTrue();

      const compatibleLine = SyncDataHelper.convertToLineProtocolLine(
        TEST_MEASUREMENT,
        new Map(),
        fields,
        TEST_TIMESTAMP,
        true
      );
      expect(compatibleLine.includes('integer_value=1i')).assertFalse();
      expect(compatibleLine.includes('integer_value=1')).assertTrue();
    });

    it('dataIntegerCompatibleConfigShouldDriveLineProtocolFormatting', 0, () => {
      const config = FTSDKConfig.builder('http://www.test.url').enableDataIntegerCompatible();
      const fields: Map<string, string> = new Map();
      fields.set('test_value', '1');

      const lineProtocol = SyncDataHelper.convertToLineProtocolLine(
        TEST_MEASUREMENT,
        new Map(),
        fields,
        TEST_TIMESTAMP,
        config.isDataIntegerCompatible()
      );

      expect(config.isDataIntegerCompatible()).assertTrue();
      expect(lineProtocol.includes('test_value=1i')).assertFalse();
      expect(lineProtocol.includes('test_value=1')).assertTrue();
    });

    it('lineProtocolShouldValidateInputsAndOmitZeroTimestamp', 0, () => {
      let measurementThrown = false;
      try {
        SyncDataHelper.convertToLineProtocolLine('', new Map(), new Map(), TEST_TIMESTAMP, false);
      } catch (error) {
        measurementThrown = true;
      }

      let fieldsThrown = false;
      try {
        const nullFields = nullableTestValue<Map<string, string>>(null);
        SyncDataHelper.convertToLineProtocolLine(
          TEST_MEASUREMENT,
          new Map(),
          nullFields,
          TEST_TIMESTAMP,
          false
        );
      } catch (error) {
        fieldsThrown = true;
      }

      const fields: Map<string, string> = new Map();
      fields.set('message', 'hello');
      const lineProtocol = SyncDataHelper.convertToLineProtocolLine(TEST_MEASUREMENT, new Map(), fields, 0, false);

      expect(measurementThrown).assertTrue();
      expect(fieldsThrown).assertTrue();
      expect(lineProtocol).assertEqual(`${TEST_MEASUREMENT} message="hello"`);
    });

    it('when fields map is null should throw immediately with stable behavior', 0, () => {
      let nullThrown = false;

      try {
        const nullFields = nullableTestValue<Map<string, string>>(null);
        SyncDataHelper.convertToLineProtocolLine(
          TEST_MEASUREMENT,
          new Map(),
          nullFields,
          TEST_TIMESTAMP,
          false
        );
      } catch (error) {
        nullThrown = true;
      }

      expect(nullThrown).assertTrue();
    });

    it('when tags/fields passed with duplicate keys alongside dynamic contexts should honor explicit precedence', 0, () => {
      const helper = new SyncDataHelper();
      const baseConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .addGlobalContext('shared', 'base' as Object)
        .addGlobalContext('other', 'base-static' as Object);
      const logConfig = new FTLoggerConfig()
        .addGlobalContext('shared', 'log-static')
        .addGlobalContext('other', 'log-static');

      helper.initBaseConfig(baseConfig);
      helper.initLogConfig(logConfig);
      helper.appendGlobalContextByKeyValue('shared', 'dynamic-base');
      helper.appendLogGlobalContextByKeyValue('shared', 'dynamic-log');

      const tags: Map<string, string> = new Map();
      tags.set('shared', 'passed');
      tags.set('other', 'passed-tag');
      const fields: Map<string, string> = new Map();
      fields.set('message', 'hello');

      const lineProtocol = helper.getBodyContent(
        TEST_MEASUREMENT,
        tags,
        fields,
        TEST_TIMESTAMP,
        DataType.LOG,
        'uuid-log'
      );

      expect(lineProtocol.includes('shared=passed')).assertTrue();
      expect(lineProtocol.includes('shared=dynamic-base')).assertFalse();
      expect(lineProtocol.includes('shared=dynamic-log')).assertFalse();
      expect(lineProtocol.includes('other=passed-tag')).assertTrue();
      expect(lineProtocol.includes('other=base')).assertFalse();
    });

    it('configGlobalContextShouldCoverStringObjectAndPrimitiveValueBranches', 0, () => {
      const helper = new SyncDataHelper();
      const baseConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .addGlobalContext('base_string', 'base-value' as Object)
        .addGlobalContext('base_number', 7 as Object);
      const logConfig = new FTLoggerConfig();
      logConfig.getGlobalContext().set('log_string_direct', 'direct-log' as Object);
      logConfig.getGlobalContext().set('log_number_direct', 9 as Object);
      logConfig.addGlobalContext('log_string_object', 'wrapped-log');
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext('rum_string', 'rum-value' as Object)
        .addGlobalContext('rum_number', 11 as Object);

      helper.initBaseConfig(baseConfig);
      helper.initRUMConfig(rumConfig);
      helper.initLogConfig(logConfig);

      const logFields = new Map<string, string>();
      logFields.set('message', 'hello');
      const logLine = helper.getBodyContent(
        TEST_MEASUREMENT,
        new Map(),
        logFields,
        TEST_TIMESTAMP,
        DataType.LOG,
        'uuid-log-config-branches'
      );

      const rumFields = new Map<string, string>();
      rumFields.set('view_name', 'Home');
      const rumLine = helper.getBodyContent(
        'rum_view',
        new Map(),
        rumFields,
        TEST_TIMESTAMP,
        DataType.RUM_APP,
        'uuid-rum-config-branches'
      );

      expect(logLine.includes('base_string=base-value')).assertTrue();
      expect(logLine.includes('base_number=7')).assertTrue();
      expect(logLine.includes('log_string_direct=direct-log')).assertTrue();
      expect(logLine.includes('log_number_direct=9')).assertTrue();
      expect(logLine.includes('log_string_object=wrapped-log')).assertTrue();
      expect(rumLine.includes('rum_string=rum-value')).assertTrue();
      expect(rumLine.includes('rum_number=11')).assertTrue();
    });

    it('when dynamic context map is empty/null should not mutate output', 0, () => {
      const helper = new SyncDataHelper();
      const baseConfig = FTSDKConfig.builder(TEST_FAKE_URL).addGlobalContext('base-only', 'value' as Object);
      helper.initBaseConfig(baseConfig);
      helper.initLogConfig(new FTLoggerConfig());
      helper.appendGlobalContext(new Map<string, string>());
      helper.appendGlobalContextByKeyValue('', '');
      helper.appendLogGlobalContext(new Map<string, string>());
      helper.appendLogGlobalContextByKeyValue('', '');

      const tags: Map<string, string> = new Map();
      tags.set('static', 'tag-value');
      const fields: Map<string, string> = new Map();
      fields.set('message', 'hello');
      const lineProtocol = helper.getBodyContent(
        TEST_MEASUREMENT,
        tags,
        fields,
        TEST_TIMESTAMP,
        DataType.LOG,
        'uuid-log-null'
      );

      expect(lineProtocol.includes('base-only=value')).assertTrue();
      expect(lineProtocol.includes('static=tag-value')).assertTrue();
      expect(lineProtocol.includes('message="hello"')).assertTrue();
    });

    it('when value types are null/whitespace/boolean-like strings should serialize stably', 0, () => {
      const fields = new Map<string, string>();
      fields.set('null-field', nullableTestValue<string>(null));
      fields.set('empty-field', '   ');
      fields.set('bool-true', 'true');
      fields.set('bool-false', 'false');
      fields.set('bool-short', 'T');
      fields.set('number-string', '123');
      fields.set('float-string', '3.5');
      fields.set('quoted-field', '"abc"');

      const lineProtocol = SyncDataHelper.convertToLineProtocolLine(
        TEST_MEASUREMENT,
        new Map(),
        fields,
        TEST_TIMESTAMP,
        false
      );

      expect(lineProtocol.includes('null-field')).assertFalse();
      expect(lineProtocol.includes('empty-field="   "')).assertTrue();
      expect(lineProtocol.includes('bool-true=true')).assertTrue();
      expect(lineProtocol.includes('bool-false=false')).assertTrue();
      expect(lineProtocol.includes('bool-short=T')).assertTrue();
      expect(lineProtocol.includes('number-string=123i')).assertTrue();
      expect(lineProtocol.includes('float-string=3.5')).assertTrue();
      expect(lineProtocol.includes('quoted-field="abc"')).assertTrue();
    });

    it('when convertToLineProtocolLine roundtrips through deserialize expectation should keep semantic equivalence', 0, () => {
      const tags = new Map<string, string>();
      tags.set('service', 'api');
      tags.set('region', 'us-east');

      const fields = new Map<string, string>();
      fields.set('message', 'hello');
      fields.set('count', '42');
      fields.set('ratio', '3.14');
      fields.set('enabled', 'true');

      const lineProtocol = SyncDataHelper.convertToLineProtocolLine(
        TEST_MEASUREMENT,
        tags,
        fields,
        TEST_TIMESTAMP,
        false
      );
      const parsed = parseLineProtocol(lineProtocol);

      expect(parsed.tags.get('service')).assertEqual('api');
      expect(parsed.tags.get('region')).assertEqual('us-east');
      expect(parsed.fields.get('message')).assertEqual('hello');
      expect(parsed.fields.get('count')).assertEqual('42');
      expect(parsed.fields.get('ratio')).assertEqual('3.14');
      expect(parsed.fields.get('enabled')).assertEqual('true');
    });

    it('getCustomHashShouldSerializeNonStringFieldBranches', 0, () => {
      const fields = new Map<string, string>();
      fields.set('number_value', 7 as Object as string);
      fields.set('float_value', 1.5 as Object as string);
      fields.set('boolean_value', true as Object as string);
      fields.set('value_wrapper', new ValueFieldWrapper('"wrapped value"') as Object as string);
      fields.set('getter_wrapper', new GetterFieldWrapper() as Object as string);
      fields.set('throwing_getter', new ThrowingGetterFieldWrapper() as Object as string);
      fields.set('json_string', new JsonStringFieldWrapper() as Object as string);
      fields.set('bad_json_string', new BadJsonStringFieldWrapper() as Object as string);

      const customHash = SyncDataHelper.getCustomHash(fields, false, false);

      expect(customHash.includes('number_value=7i')).assertTrue();
      expect(customHash.includes('float_value=1.5')).assertTrue();
      expect(customHash.includes('boolean_value=true')).assertTrue();
      expect(customHash.includes('value_wrapper="wrapped value"')).assertTrue();
      expect(customHash.includes('getter_wrapper="getter value"')).assertTrue();
      expect(customHash.includes('throwing_getter="fallback value"')).assertTrue();
      expect(customHash.includes('json_string="json value"')).assertTrue();
      expect(customHash.includes('bad_json_string="{\\"value\\":"')).assertTrue();
    });

    it('getCustomHashShouldLogWhenGetterAndFallbackToStringBothFail', 0, () => {
      const fields = new Map<string, string>();
      fields.set('bad_object', new ThrowingGetterAndToStringFieldWrapper() as Object as string);

      const customHash = SyncDataHelper.getCustomHash(fields, false, false);

      expect(customHash.includes('bad_object')).assertFalse();
    });

    it('getCustomHashShouldSerializeObjectFallbackAndIntegerCompatibleBranches', 0, () => {
      const fields = new Map<string, string>();
      fields.set('number_value', 7 as Object as string);
      fields.set('integer_string_default', '41');
      fields.set('quoted_json_value', '{"value":"\\"quoted value\\""}');
      fields.set('json_integer_value', '{"value":"41"}');
      fields.set('json_without_value', '{"other":"string object"}');
      fields.set('bad_json_closed', '{"value":}');
      fields.set('bool_short_false', 'F');
      fields.set('object_json_without_value', new JsonNoValueStringFieldWrapper() as Object as string);
      fields.set('object_bad_closed_json', new BadClosedJsonStringFieldWrapper() as Object as string);
      fields.set('object_plain', new PlainStringFieldWrapper() as Object as string);
      fields.set('object_throwing_to_string', new ThrowingToStringFieldWrapper() as Object as string);

      const customHash = SyncDataHelper.getCustomHash(fields, false, true);

      expect(customHash.includes('number_value=7')).assertTrue();
      expect(customHash.includes('number_value=7i')).assertFalse();
      expect(customHash.includes('integer_string_default=41')).assertTrue();
      expect(customHash.includes('quoted_json_value="quoted value"')).assertTrue();
      expect(customHash.includes('json_integer_value=41')).assertTrue();
      expect(customHash.includes('json_integer_value=41i')).assertFalse();
      expect(customHash.includes('json_without_value="{\\"other\\":\\"string object\\"}"')).assertTrue();
      expect(customHash.includes('bad_json_closed="{\\"value\\":}"')).assertTrue();
      expect(customHash.includes('bool_short_false=F')).assertTrue();
      expect(customHash.includes('object_json_without_value="{\\"other\\":\\"json object\\"}"')).assertTrue();
      expect(customHash.includes('object_bad_closed_json="{\\"value\\":}"')).assertTrue();
      expect(customHash.includes('object_plain="plain object value"')).assertTrue();
      expect(customHash.includes('object_throwing_to_string="{\\"fallback\\":\\"json fallback value\\"}"')).assertTrue();
    });

    it('getCustomHashShouldCoverCompatibleIntegerStringAndQuotedJsonObjectBranches', 0, () => {
      const fields = new Map<string, string>();
      fields.set('integer_string_compatible', '42');
      fields.set('quoted_json_object', new QuotedJsonStringFieldWrapper() as Object as string);

      const customHash = SyncDataHelper.getCustomHash(fields, false, true);

      expect(customHash.includes('integer_string_compatible=42')).assertTrue();
      expect(customHash.includes('integer_string_compatible=42i')).assertFalse();
      expect(customHash.includes('quoted_json_object="quoted object value"')).assertTrue();
    });

    it('getCustomHashShouldSerializeObjectTagBranches', 0, () => {
      const tags = new Map<string, string>();
      tags.set('value_wrapper_tag', new ValueFieldWrapper('tag value') as Object as string);
      tags.set('getter_wrapper_tag', new GetterFieldWrapper() as Object as string);
      tags.set('throwing_getter_tag', new ThrowingGetterFieldWrapper() as Object as string);
      tags.set('json_string_tag', new JsonStringFieldWrapper() as Object as string);
      tags.set('json_without_value_tag', new JsonNoValueStringFieldWrapper() as Object as string);
      tags.set('bad_json_string_tag', new BadClosedJsonStringFieldWrapper() as Object as string);
      tags.set('plain_object_tag', new PlainStringFieldWrapper() as Object as string);
      tags.set('throwing_to_string_tag', new ThrowingToStringFieldWrapper() as Object as string);
      tags.set('function_value_tag', (() => 'ignored') as Object as string);

      const customHash = SyncDataHelper.getCustomHash(tags, true, false);

      expect(customHash.includes('value_wrapper_tag=tag\\ value')).assertTrue();
      expect(customHash.includes('getter_wrapper_tag=getter\\ value')).assertTrue();
      expect(customHash.includes('throwing_getter_tag=fallback\\ value')).assertTrue();
      expect(customHash.includes('json_string_tag=json\\ value')).assertTrue();
      expect(customHash.includes('json_without_value_tag={"other":"json\\ object"}')).assertTrue();
      expect(customHash.includes('bad_json_string_tag={"value":}')).assertTrue();
      expect(customHash.includes('plain_object_tag=plain\\ object\\ value')).assertTrue();
      expect(customHash.includes('throwing_to_string_tag={"fallback":"json\\ fallback\\ value"}')).assertTrue();
      expect(customHash.includes('function_value_tag')).assertFalse();
    });

    it('contextAppendMethodsShouldIgnoreNullOrBlankRumInput', 0, () => {
      const helper = new SyncDataHelper();
      helper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL).addGlobalContext('base', 'value' as Object));
      helper.initRUMConfig(new FTRUMConfig().setRumAppId('rum-id'));

      helper.appendGlobalContext(nullableTestValue<Map<string, string>>(null));
      helper.appendLogGlobalContext(nullableTestValue<Map<string, string>>(null));
      helper.appendRUMGlobalContext(nullableTestValue<Map<string, string>>(null));
      helper.appendRUMGlobalContextByKeyValue('', '');

      const fields = new Map<string, string>();
      fields.set('view_name', 'Home');
      const lineProtocol = helper.getBodyContent(
        'rum_view',
        nullableTestValue<Map<string, string>>(null),
        fields,
        TEST_TIMESTAMP,
        DataType.RUM_APP,
        'uuid-rum-null-context'
      );

      expect(lineProtocol.includes('base=value')).assertTrue();
      expect(lineProtocol.includes(Constants.KEY_RUM_CUSTOM_KEYS)).assertFalse();
      expect(lineProtocol.includes('view_name="Home"')).assertTrue();
    });

    it('contextAppendMethodsShouldApplyNonEmptyBaseAndLogMaps', 0, () => {
      const helper = new SyncDataHelper();
      const baseContext = new Map<string, string>();
      baseContext.set('base_dynamic_map', 'base-map-value');
      const logContext = new Map<string, string>();
      logContext.set('log_dynamic_map', 'log-map-value');
      const fields = new Map<string, string>();
      fields.set('message', 'hello');

      helper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL));
      helper.initLogConfig(new FTLoggerConfig());
      helper.appendGlobalContext(baseContext);
      helper.appendLogGlobalContext(logContext);

      const lineProtocol = helper.getBodyContent(
        TEST_MEASUREMENT,
        new Map(),
        fields,
        TEST_TIMESTAMP,
        DataType.LOG,
        'uuid-log-dynamic-map-context'
      );

      expect(lineProtocol.includes('base_dynamic_map=base-map-value')).assertTrue();
      expect(lineProtocol.includes('log_dynamic_map=log-map-value')).assertTrue();
    });

    it('rumCustomKeysShouldCoverDuplicateAndMissingExistingKeyBranches', 0, () => {
      const helper = new SyncDataHelper();
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext(Constants.KEY_RUM_CUSTOM_KEYS, '["same_key"]' as Object);
      const dynamicContext = new Map<string, string>();
      dynamicContext.set('same_key', 'from-map');

      helper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL));
      helper.initRUMConfig(rumConfig);
      helper.appendRUMGlobalContext(dynamicContext);
      helper.appendRUMGlobalContextByKeyValue('same_key', 'from-key-value');

      const noExistingHelper = new SyncDataHelper();
      noExistingHelper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL));
      noExistingHelper.initRUMConfig(new FTRUMConfig().setRumAppId('rum-id'));
      noExistingHelper.appendRUMGlobalContextByKeyValue('fresh_key', 'fresh-value');

      const fields = new Map<string, string>();
      fields.set('view_name', 'Home');
      const duplicateLine = helper.getBodyContent(
        'rum_view',
        new Map(),
        new Map(fields),
        TEST_TIMESTAMP,
        DataType.RUM_APP,
        'uuid-rum-duplicate-custom-keys'
      );
      const freshLine = noExistingHelper.getBodyContent(
        'rum_view',
        new Map(),
        new Map(fields),
        TEST_TIMESTAMP,
        DataType.RUM_APP,
        'uuid-rum-fresh-custom-keys'
      );

      expect(duplicateLine.includes('same_key=from-key-value')).assertTrue();
      expect(duplicateLine.includes('custom_keys=["same_key"]')).assertTrue();
      expect(duplicateLine.includes('["same_key","same_key"]')).assertFalse();
      expect(freshLine.includes('fresh_key=fresh-value')).assertTrue();
      expect(freshLine.includes('custom_keys=["fresh_key"]')).assertTrue();
    });

    it('rumCustomKeysShouldRecoverWhenExistingCustomKeysIsInvalidJson', 0, () => {
      const helper = new SyncDataHelper();
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext(Constants.KEY_RUM_CUSTOM_KEYS, 'not-json' as Object);
      const fields = new Map<string, string>();
      fields.set('view_name', 'Home');

      helper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL));
      helper.initRUMConfig(rumConfig);
      helper.appendRUMGlobalContextByKeyValue('fresh_after_bad_json', 'fresh-value');

      const lineProtocol = helper.getBodyContent(
        'rum_view',
        new Map(),
        fields,
        TEST_TIMESTAMP,
        DataType.RUM_APP,
        'uuid-rum-bad-custom-keys'
      );

      expect(lineProtocol.includes('fresh_after_bad_json=fresh-value')).assertTrue();
      expect(lineProtocol.includes('custom_keys=["fresh_after_bad_json"]')).assertTrue();
      expect(lineProtocol.includes('not-json')).assertFalse();
    });

    it('checkSessionWillCollectShouldCoverEmptySamplingDropAndErrorFallbackBranches', 0, () => {
      const helper = new SyncDataHelper();
      const manager = FTRUMInnerManager.getInstance();
      const sessionId = manager.getSessionId();

      expect(helper.checkSessionWillCollect('')).assertTrue();

      manager.setSamplingRates(1, 0);
      expect(helper.checkSessionWillCollect(sessionId)).assertTrue();

      manager.setSamplingRates(0, 1);
      expect(helper.checkSessionWillCollect(sessionId)).assertFalse();

      manager.setSamplingRates(0, 0);
      expect(helper.checkSessionWillCollect(sessionId)).assertFalse();

      const managerRecord = manager as Object as Record<string, object>;
      const originalCheck = managerRecord['checkSessionWillCollect'];
      managerRecord['checkSessionWillCollect'] = ((_sessionId?: string) => {
        throw new Error('sampling check failed');
      }) as Object;

      try {
        expect(helper.checkSessionWillCollect('session-error-fallback')).assertTrue();
      } finally {
        managerRecord['checkSessionWillCollect'] = originalCheck;
        manager.setSamplingRates(1, 0);
      }
    });

    it('translateHelpersShouldCoverEmptyJsonAndSpecialCharacterBranches', 0, () => {
      expect(SyncDataHelper.translateTagKeyValue('')).assertEqual('');
      expect(SyncDataHelper.translateTagKeyValue('a\\b\nc=d,e')).assertEqual('ab\\ c\\=d\\,e');
      expect(SyncDataHelper.translateTagKeyValueForJson('')).assertEqual('');
      expect(SyncDataHelper.translateTagKeyValueForJson('{"a":"b",\n"c":"d"}')).assertEqual('{"a":"b"\\,\\ "c":"d"}');
      expect(SyncDataHelper.translateMeasurements('')).assertEqual('');
      expect(SyncDataHelper.translateMeasurements('a\\b,c d')).assertEqual('ab\\,c\\ d');
      expect(SyncDataHelper.translateFieldValue('')).assertEqual('""');
      expect(SyncDataHelper.translateFieldValue('a\\b"c')).assertEqual('"a\\\\b\\"c"');
      expect(SyncDataHelper.translateSpecialCharacters('', 'abc')).assertEqual('abc');
      expect(SyncDataHelper.translateSpecialCharacters(',', '')).assertEqual('');
    });

    it('getBodyContentShouldCoverDefaultTypeAndRumCustomKeyRecovery', 0, () => {
      const helper = new SyncDataHelper();
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext(Constants.KEY_RUM_CUSTOM_KEYS, 'not-json' as Object);
      const rumContext = new Map<string, string>();
      rumContext.set('rum_dynamic_recovered', 'value');
      const fields = new Map<string, string>();
      fields.set('message', 'default branch');

      helper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL).addGlobalContext('base_tag', 'base-value' as Object));
      helper.initRUMConfig(rumConfig);
      helper.appendRUMGlobalContext(rumContext);

      const defaultLine = helper.getBodyContent(
        TEST_MEASUREMENT,
        new Map(),
        fields,
        TEST_TIMESTAMP,
        'unknown' as Object as DataType,
        'uuid-default'
      );
      const rumFields = new Map<string, string>();
      rumFields.set('view_name', 'Home');
      const rumLine = helper.getBodyContent(
        'rum_view',
        new Map(),
        rumFields,
        TEST_TIMESTAMP,
        DataType.RUM_APP,
        'uuid-rum-recovered'
      );

      expect(defaultLine.includes('base_tag=base-value')).assertTrue();
      expect(defaultLine.includes('message="default branch"')).assertTrue();
      expect(rumLine.includes('rum_dynamic_recovered=value')).assertTrue();
      expect(rumLine.includes('custom_keys=["rum_dynamic_recovered"]')).assertTrue();
    });

    it('lineProtocolShouldFormatBoundaryFieldValues', 0, () => {
      const fields: Map<string, string> = new Map();
      fields.set('empty', '');
      fields.set('negative', '-42');
      fields.set('float_value', '3.5');
      fields.set('bool_true', 'true');
      fields.set('bool_short', 'T');
      fields.set('wrapped', '{"value":"harmonyos"}');

      const lineProtocol = SyncDataHelper.convertToLineProtocolLine(
        TEST_MEASUREMENT,
        new Map(),
        fields,
        TEST_TIMESTAMP,
        false
      );

      expect(lineProtocol.includes('empty=')).assertFalse();
      expect(lineProtocol.includes('negative=-42i')).assertTrue();
      expect(lineProtocol.includes('float_value=3.5')).assertTrue();
      expect(lineProtocol.includes('bool_true=true')).assertTrue();
      expect(lineProtocol.includes('bool_short=T')).assertTrue();
      expect(lineProtocol.includes('wrapped="harmonyos"')).assertTrue();
    });

    it('sdkPackageInfoJsonTagShouldEscapeCommaAndSpace', 0, () => {
      const tags: Map<string, string> = new Map();
      tags.set(Constants.KEY_SDK_PACKAGE_INFO, '{"agent":"1.0.0", "native":"1.0.0"}');
      const fields: Map<string, string> = new Map();
      fields.set('message', 'hello');

      const lineProtocol = SyncDataHelper.convertToLineProtocolLine(
        TEST_MEASUREMENT,
        tags,
        fields,
        TEST_TIMESTAMP,
        false
      );

      expect(lineProtocol.includes('sdk_pkg_info={"agent":"1.0.0"\\,\\ "native":"1.0.0"}')).assertTrue();
    });

    it('getBodyContentShouldMergeLogContextWithExpectedPriority', 0, () => {
      const helper = new SyncDataHelper();
      const baseConfig = FTSDKConfig.builder('http://www.test.url')
        .addGlobalContext('shared', 'base' as Object)
        .addGlobalContext('base_only', 'base-value' as Object);
      const logConfig = new FTLoggerConfig()
        .addGlobalContext('shared', 'log-static')
        .addGlobalContext('log_only', 'log-value');

      helper.initBaseConfig(baseConfig);
      helper.initLogConfig(logConfig);
      helper.appendGlobalContextByKeyValue('shared', 'dynamic-base');
      helper.appendLogGlobalContextByKeyValue('shared', 'dynamic-log');

      const tags: Map<string, string> = new Map();
      tags.set('shared', 'passed');
      const fields: Map<string, string> = new Map();
      fields.set('message', 'hello');

      const lineProtocol = helper.getBodyContent(
        TEST_MEASUREMENT,
        tags,
        fields,
        TEST_TIMESTAMP,
        DataType.LOG,
        'uuid-log'
      );

      expect(lineProtocol.includes('shared=passed')).assertTrue();
      expect(lineProtocol.includes('base_only=base-value')).assertTrue();
      expect(lineProtocol.includes('log_only=log-value')).assertTrue();
      expect(lineProtocol.includes('shared=dynamic-log')).assertFalse();
      expect(lineProtocol.includes('shared=log-static')).assertFalse();
      expect(lineProtocol.includes('shared=base')).assertFalse();

      const fieldsWithoutPassed: Map<string, string> = new Map();
      fieldsWithoutPassed.set('message', 'hello');
      const lineWithoutPassed = helper.getBodyContent(
        TEST_MEASUREMENT,
        new Map(),
        fieldsWithoutPassed,
        TEST_TIMESTAMP,
        DataType.LOG,
        'uuid-log-2'
      );

      expect(lineWithoutPassed.includes('shared=dynamic-log')).assertTrue();
      expect(lineWithoutPassed.includes('shared=log-static')).assertFalse();
      expect(lineWithoutPassed.includes('shared=dynamic-base')).assertFalse();
    });

    it('getBodyContentShouldLinkRumTagsIntoLogWhenEnabled', 0, () => {
      const helper = new SyncDataHelper();
      const baseConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .addGlobalContext('base_only', 'base-value' as Object);
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext('rum_only', 'rum-value' as Object);
      const logConfig = new FTLoggerConfig()
        .setEnableLinkRumData(true)
        .addGlobalContext('log_only', 'log-value');

      helper.initBaseConfig(baseConfig);
      helper.initRUMConfig(rumConfig);
      helper.initLogConfig(logConfig);

      const fields = new Map<string, string>();
      fields.set('message', 'linked log');
      const lineProtocol = helper.getBodyContent(
        TEST_MEASUREMENT,
        new Map(),
        fields,
        TEST_TIMESTAMP,
        DataType.LOG,
        'uuid-log-rum-link'
      );

      expect(lineProtocol.includes('base_only=base-value')).assertTrue();
      expect(lineProtocol.includes('log_only=log-value')).assertTrue();
      expect(lineProtocol.includes('rum_only=rum-value')).assertTrue();
      expect(lineProtocol.includes('message="linked log"')).assertTrue();
    });

    it('getBodyContentShouldAddRumStaticFieldsAndCustomKeys', 0, () => {
      const helper = new SyncDataHelper();
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .setSamplingRate(0.25)
        .setSessionErrorSampleRate(0.75)
        .addGlobalContext('rum_static', 'static-value' as Object);
      const dynamicRumContext: Map<string, string> = new Map();
      dynamicRumContext.set('rum_dynamic', 'dynamic-value');

      helper.initBaseConfig(FTSDKConfig.builder('http://www.test.url'));
      helper.initRUMConfig(rumConfig);
      helper.appendRUMGlobalContext(dynamicRumContext);
      helper.appendRUMGlobalContextByKeyValue('rum_dynamic', 'dynamic-value-2');

      const fields: Map<string, string> = new Map();
      fields.set('view_name', 'Home');
      const lineProtocol = helper.getBodyContent(
        'rum_view',
        new Map(),
        fields,
        TEST_TIMESTAMP,
        DataType.RUM_APP,
        'uuid-rum'
      );
      const parsed = parseLineProtocol(lineProtocol);
      const customKeys = parsed.tags.get(Constants.KEY_RUM_CUSTOM_KEYS) || '';

      console.info('SyncDataHelperUnit', `rum static fields line=${lineProtocol}`);
      expect(parsed.tags.get('rum_static')).assertEqual('static-value');
      expect(parsed.tags.get('rum_dynamic')).assertEqual('dynamic-value-2');
      expect(customKeys.includes('rum_dynamic')).assertTrue();
      expect(parsed.fields.get(Constants.KEY_SESSION_SAMPLE_RATE)).assertEqual('0.25');
      expect(parsed.fields.get(Constants.KEY_SESSION_ON_ERROR_SAMPLE_RATE)).assertEqual('0.75');
    });

    it('getBodyContentShouldPreserveWebViewServiceAndAppendWebVersion', 0, () => {
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

      helper.initBaseConfig(FTSDKConfig.builder('http://www.test.url'));
      helper.initRUMConfig(rumConfig);

      const lineProtocol = helper.getBodyContent(
        'browser_sdk',
        tags,
        fields,
        TEST_TIMESTAMP,
        DataType.RUM_WEBVIEW,
        'uuid-web'
      );

      expect(lineProtocol.includes('service=browser')).assertTrue();
      expect(lineProtocol.includes('service=native-service')).assertFalse();
      expect(lineProtocol.includes('"web":"2.0.0"')).assertTrue();
      expect(lineProtocol.includes('"agent":"1.0.0"')).assertTrue();
    });

    it('getBodyContentShouldHandleWebViewWithoutSdkPackageInfo', 0, () => {
      const helper = new SyncDataHelper();
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext('web_other_tag', 'other-value' as Object);
      const fields = new Map<string, string>();
      fields.set('view_name', 'web');

      helper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL));
      helper.initRUMConfig(rumConfig);

      const lineProtocol = helper.getBodyContent(
        'browser_sdk',
        new Map(),
        fields,
        TEST_TIMESTAMP,
        DataType.RUM_WEBVIEW,
        'uuid-web-no-sdk-pkg-info'
      );

      expect(lineProtocol.includes('web_other_tag=other-value')).assertTrue();
      expect(lineProtocol.includes(Constants.KEY_SDK_PACKAGE_INFO)).assertFalse();
    });

    it('getBodyContentShouldAppendEmptyWebVersionWhenWebViewSdkVersionMissing', 0, () => {
      const helper = new SyncDataHelper();
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext(Constants.KEY_SDK_PACKAGE_INFO, '{"agent":"1.0.0"}' as Object);
      const fields = new Map<string, string>();
      fields.set('view_name', 'web');

      helper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL));
      helper.initRUMConfig(rumConfig);

      const lineProtocol = helper.getBodyContent(
        'browser_sdk',
        new Map(),
        fields,
        TEST_TIMESTAMP,
        DataType.RUM_WEBVIEW,
        'uuid-web-empty-version'
      );

      expect(lineProtocol.includes('"web":""')).assertTrue();
      expect(lineProtocol.includes('"agent":"1.0.0"')).assertTrue();
    });

    it('getBodyContentShouldPreserveEscapedExistingWebVersionInSdkPackageInfo', 0, () => {
      const helper = new SyncDataHelper();
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext(Constants.KEY_SDK_PACKAGE_INFO,
          '{\\"web\\":\\"1.0.0\\",\\"agent\\":\\"1.0.0\\"}' as Object);
      const tags = new Map<string, string>();
      tags.set(Constants.KEY_SDK_VERSION, '2.0.0');
      const fields = new Map<string, string>();
      fields.set('view_name', 'web');

      helper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL));
      helper.initRUMConfig(rumConfig);

      const lineProtocol = helper.getBodyContent(
        'browser_sdk',
        tags,
        fields,
        TEST_TIMESTAMP,
        DataType.RUM_WEBVIEW,
        'uuid-web-escaped-existing-version'
      );

      expect(lineProtocol.includes('"web":"1.0.0"')).assertTrue();
      expect(lineProtocol.includes('"web":"2.0.0"')).assertFalse();
      expect(lineProtocol.includes('"agent":"1.0.0"')).assertTrue();
    });

    it('getBodyContentShouldPreserveExistingWebVersionInSdkPackageInfo', 0, () => {
      const helper = new SyncDataHelper();
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext(Constants.KEY_SDK_PACKAGE_INFO, '{"web":"1.0.0", "agent":"1.0.0"}' as Object);
      const tags = new Map<string, string>();
      tags.set(Constants.KEY_SDK_VERSION, '2.0.0');
      const fields = new Map<string, string>();
      fields.set('view_name', 'web');

      helper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL));
      helper.initRUMConfig(rumConfig);

      const lineProtocol = helper.getBodyContent(
        'browser_sdk',
        tags,
        fields,
        TEST_TIMESTAMP,
        DataType.RUM_WEBVIEW,
        'uuid-web-existing-version'
      );

      expect(lineProtocol.includes('"web":"1.0.0"')).assertTrue();
      expect(lineProtocol.includes('"web":"2.0.0"')).assertFalse();
      expect(lineProtocol.includes('"agent":"1.0.0"')).assertTrue();
    });

    it('getBodyContentShouldKeepNonJsonSdkPackageInfoForWebView', 0, () => {
      const helper = new SyncDataHelper();
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext(Constants.KEY_SDK_PACKAGE_INFO, 'plain-package-info' as Object);
      const tags = new Map<string, string>();
      tags.set(Constants.KEY_SDK_VERSION, '2.0.0');
      const fields = new Map<string, string>();
      fields.set('view_name', 'web');

      helper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL));
      helper.initRUMConfig(rumConfig);

      const lineProtocol = helper.getBodyContent(
        'browser_sdk',
        tags,
        fields,
        TEST_TIMESTAMP,
        DataType.RUM_WEBVIEW,
        'uuid-web-plain-pkg-info'
      );

      expect(lineProtocol.includes(`${Constants.KEY_SDK_PACKAGE_INFO}=plain-package-info`)).assertTrue();
      expect(lineProtocol.includes('"web":"2.0.0"')).assertFalse();
    });

    it('getBodyContentShouldRecoverEscapedOrInvalidSdkPackageInfoForWebView', 0, () => {
      const escapedHelper = new SyncDataHelper();
      const escapedRumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext(Constants.KEY_SDK_PACKAGE_INFO, '{\\"agent\\":\\"1.0.0\\"}' as Object);
      const escapedTags = new Map<string, string>();
      escapedTags.set(Constants.KEY_SDK_VERSION, '2.0.0');
      const escapedFields = new Map<string, string>();
      escapedFields.set('view_name', 'web');

      escapedHelper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL));
      escapedHelper.initRUMConfig(escapedRumConfig);

      const escapedLine = escapedHelper.getBodyContent(
        'browser_sdk',
        escapedTags,
        escapedFields,
        TEST_TIMESTAMP,
        DataType.RUM_WEBVIEW,
        'uuid-web-escaped-pkg-info'
      );

      const invalidHelper = new SyncDataHelper();
      const invalidRumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext(Constants.KEY_SDK_PACKAGE_INFO, '{bad json}' as Object);
      const invalidTags = new Map<string, string>();
      invalidTags.set(Constants.KEY_SDK_VERSION, 'web-sdk-name');
      const invalidFields = new Map<string, string>();
      invalidFields.set('view_name', 'web');

      invalidHelper.initBaseConfig(FTSDKConfig.builder(TEST_FAKE_URL));
      invalidHelper.initRUMConfig(invalidRumConfig);

      const invalidLine = invalidHelper.getBodyContent(
        'browser_sdk',
        invalidTags,
        invalidFields,
        TEST_TIMESTAMP,
        DataType.RUM_WEBVIEW,
        'uuid-web-invalid-pkg-info'
      );

      expect(escapedLine.includes('"web":"2.0.0"')).assertTrue();
      expect(escapedLine.includes('"agent":"1.0.0"')).assertTrue();
      expect(invalidLine.includes('"web":"web-sdk-name"')).assertTrue();
      expect(invalidLine.includes('bad\\ json')).assertTrue();
    });

    it('getBodyContentShouldHandleQuotedSdkPackageInfoAfterLineModifier', 0, () => {
      const helper = new SyncDataHelper();
      const baseConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setLineDataModifier(new QuoteSdkPackageInfoLineDataModifier());
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext(Constants.KEY_SDK_PACKAGE_INFO, '{"agent":"1.0.0"}' as Object);
      const tags = new Map<string, string>();
      tags.set(Constants.KEY_SDK_VERSION, '2.0.0');
      const fields = new Map<string, string>();
      fields.set('view_name', 'web');

      helper.initBaseConfig(baseConfig);
      helper.initRUMConfig(rumConfig);

      const lineProtocol = helper.getBodyContent(
        'browser_sdk',
        tags,
        fields,
        TEST_TIMESTAMP,
        DataType.RUM_WEBVIEW,
        'uuid-web-quoted-pkg-info'
      );

      expect(lineProtocol.includes('"web":"2.0.0"')).assertTrue();
      expect(lineProtocol.includes('"agent":"1.0.0"')).assertTrue();
    });

    it('getBodyContentShouldAppendWebVersionAfterLineModifierRewritesPackageInfo', 0, () => {
      const helper = new SyncDataHelper();
      const baseConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setLineDataModifier(new RewriteSdkPackageInfoLineDataModifier('{"agent":"modifier"}' as Object));
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext(Constants.KEY_SDK_PACKAGE_INFO, 'plain-package-info' as Object);
      const tags = new Map<string, string>();
      tags.set(Constants.KEY_SDK_VERSION, '2.0.0');
      const fields = new Map<string, string>();
      fields.set('view_name', 'web');

      helper.initBaseConfig(baseConfig);
      helper.initRUMConfig(rumConfig);

      const lineProtocol = helper.getBodyContent(
        'browser_sdk',
        tags,
        fields,
        TEST_TIMESTAMP,
        DataType.RUM_WEBVIEW,
        'uuid-web-modifier-json-pkg-info'
      );

      expect(lineProtocol.includes('"web":"2.0.0"')).assertTrue();
      expect(lineProtocol.includes('"agent":"modifier"')).assertTrue();
    });

    it('getBodyContentShouldUseStringFallbackAfterLineModifierWritesInvalidPackageInfo', 0, () => {
      const helper = new SyncDataHelper();
      const baseConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setLineDataModifier(new RewriteSdkPackageInfoLineDataModifier('{bad json}' as Object));
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext(Constants.KEY_SDK_PACKAGE_INFO, 'plain-package-info' as Object);
      const tags = new Map<string, string>();
      tags.set(Constants.KEY_SDK_VERSION, '2.0.0');
      const fields = new Map<string, string>();
      fields.set('view_name', 'web');

      helper.initBaseConfig(baseConfig);
      helper.initRUMConfig(rumConfig);

      const lineProtocol = helper.getBodyContent(
        'browser_sdk',
        tags,
        fields,
        TEST_TIMESTAMP,
        DataType.RUM_WEBVIEW,
        'uuid-web-modifier-invalid-pkg-info'
      );

      expect(lineProtocol.includes('"web":"2.0.0"')).assertTrue();
      expect(lineProtocol.includes('bad\\ json')).assertTrue();
    });

    it('getBodyContentShouldIgnoreNonObjectPackageInfoAfterLineModifier', 0, () => {
      const helper = new SyncDataHelper();
      const baseConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setLineDataModifier(new RewriteSdkPackageInfoLineDataModifier(123 as Object));
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext(Constants.KEY_SDK_PACKAGE_INFO, 'plain-package-info' as Object);
      const tags = new Map<string, string>();
      tags.set(Constants.KEY_SDK_VERSION, '2.0.0');
      const fields = new Map<string, string>();
      fields.set('view_name', 'web');

      helper.initBaseConfig(baseConfig);
      helper.initRUMConfig(rumConfig);

      const lineProtocol = helper.getBodyContent(
        'browser_sdk',
        tags,
        fields,
        TEST_TIMESTAMP,
        DataType.RUM_WEBVIEW,
        'uuid-web-modifier-number-pkg-info'
      );

      expect(lineProtocol.includes(`${Constants.KEY_SDK_PACKAGE_INFO}=123i`)).assertTrue();
      expect(lineProtocol.includes('"web":"2.0.0"')).assertFalse();
    });

    it('getBodyContentShouldIgnoreNullPackageInfoAfterLineModifier', 0, () => {
      const helper = new SyncDataHelper();
      const baseConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setLineDataModifier(new RewriteSdkPackageInfoLineDataModifier('null' as Object));
      const rumConfig = new FTRUMConfig()
        .setRumAppId('rum-id')
        .addGlobalContext(Constants.KEY_SDK_PACKAGE_INFO, 'plain-package-info' as Object);
      const tags = new Map<string, string>();
      tags.set(Constants.KEY_SDK_VERSION, '2.0.0');
      const fields = new Map<string, string>();
      fields.set('view_name', 'web');

      helper.initBaseConfig(baseConfig);
      helper.initRUMConfig(rumConfig);

      const lineProtocol = helper.getBodyContent(
        'browser_sdk',
        tags,
        fields,
        TEST_TIMESTAMP,
        DataType.RUM_WEBVIEW,
        'uuid-web-modifier-null-pkg-info'
      );

      expect(lineProtocol.includes(`${Constants.KEY_SDK_PACKAGE_INFO}=null`)).assertTrue();
      expect(lineProtocol.includes('"web":"2.0.0"')).assertFalse();
    });

    it('getBodyContentShouldCatchSdkPackageInfoDataModifierErrorAfterLineModifier', 0, () => {
      const helper = new SyncDataHelper();
      const baseConfig = FTSDKConfig.builder(TEST_FAKE_URL)
        .setDataModifier(new ThrowingSdkPackageInfoDataModifier());
      const rumConfig = new FTRUMConfig().setRumAppId('rum-id');
      const tags = new Map<string, string>();
      tags.set(Constants.KEY_SDK_PACKAGE_INFO, '{"agent":"line"}');
      tags.set(Constants.KEY_SDK_VERSION, '2.0.0');
      const fields = new Map<string, string>();
      fields.set('view_name', 'web');

      helper.initBaseConfig(baseConfig);
      helper.initRUMConfig(rumConfig);

      const lineProtocol = helper.getBodyContent(
        'browser_sdk',
        tags,
        fields,
        TEST_TIMESTAMP,
        DataType.RUM_WEBVIEW,
        'uuid-web-data-modifier-error'
      );

      expect(lineProtocol.includes('"agent":"line"')).assertTrue();
      expect(lineProtocol.includes('"web":"2.0.0"')).assertFalse();
    });
  });
}
