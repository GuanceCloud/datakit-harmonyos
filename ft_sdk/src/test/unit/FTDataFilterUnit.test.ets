import { describe, it, expect } from '@ohos/hypium';
import { FTDataFilter } from '../../main/ets/components/FTDataFilter';
import { DataType } from '../../main/ets/components/enum/Enums';

function filtersFor(category: string, rules: Array<string>): FTDataFilter {
  const filters = new Map<string, Array<string>>();
  filters.set(category, rules);
  return FTDataFilter.compile(filters);
}

export default function ftDataFilterUnitTest() {
  describe('FTDataFilterUnit', () => {
    it('shouldFilterLoggingAndRumWithSupportedOperators', 0, () => {
      const loggingFilter = filtersFor('logging', [
        "{ source in ['df_rum_harmonyos_log'] and message match ['.*password.*'] }",
        "{ status not in [200, 201] and enabled not match ['false'] }"
      ]);
      const logTags = new Map<string, string>();
      const logFields = new Map<string, string>();
      logFields.set('message', 'request contains password');
      expect(loggingFilter.isFiltered(DataType.LOG, 'df_rum_harmonyos_log', logTags, logFields)).assertTrue();
      expect(loggingFilter.isFiltered(DataType.LOG, 'another_measurement', logTags, logFields)).assertFalse();

      const rumFilter = filtersFor('RUM', ["{ source in [resource] and resource_status in ['404', '503'] }"]);
      const rumTags = new Map<string, string>();
      rumTags.set('resource_status', '404');
      expect(rumFilter.isFiltered(DataType.RUM_APP, 'resource', rumTags, new Map())).assertTrue();
      expect(rumFilter.isFiltered(DataType.RUM_WEBVIEW, 'resource', rumTags, new Map())).assertTrue();
    });

    it('shouldUseLineProtocolValuesAfterEscapingAndIgnoreInvalidRules', 0, () => {
      const filter = filtersFor('logging', [
        "{ message match ['secret, value'] }",
        '{ message match ["["] }',
        '{ message = unsupported }'
      ]);
      expect(filter.isFilteredLine(
        DataType.LOG,
        'df_rum_harmonyos_log,env=prod message="secret\\, value",status=200i 123'
      )).assertTrue();
      expect(filter.isFilteredLine(
        DataType.LOG,
        'df_rum_harmonyos_log,env=prod message="ordinary",status=200i 123'
      )).assertFalse();
    });

    it('shouldNotMatchMissingValuesForNegativeOperators', 0, () => {
      const filter = filtersFor('logging', ["{ missing not in ['value'] }", "{ missing not match ['.*'] }"]);
      expect(filter.isFiltered(DataType.LOG, 'df_rum_harmonyos_log', new Map(), new Map())).assertFalse();
    });
  });
}
