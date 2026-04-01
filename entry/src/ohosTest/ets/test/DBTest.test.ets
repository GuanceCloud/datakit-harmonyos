import hilog from '@ohos.hilog';
import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import relationalStore from '@ohos.data.relationalStore';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'DBTest';
const DOMAIN = 0x0001;

export default function dbTest() {
  describe('DBTestSuite', () => {
    let rdbStore: relationalStore.RdbStore | null = null;
    const tableName = 'test_table';

    beforeAll(async () => {
      hilog.info(DOMAIN, TAG, '%{public}s', 'beforeAll: init database');
      const context = globalThis.getContext();
      const config: relationalStore.StoreConfig = {
        name: 'test.db',
        securityLevel: relationalStore.SecurityLevel.S1
      };
      try {
        rdbStore = await relationalStore.getRdbStore(context, config);
        const createTableSql = `
          CREATE TABLE IF NOT EXISTS ${tableName} (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            value INTEGER,
            timestamp BIGINT
          )
        `;
        await rdbStore.executeSql(createTableSql, []);
        hilog.info(DOMAIN, TAG, '%{public}s', 'Database initialized successfully');
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'Failed to init database: %{public}s', JSON.stringify(err));
      }
    })

    afterAll(async () => {
      hilog.info(DOMAIN, TAG, '%{public}s', 'afterAll: cleanup');
      if (rdbStore) {
        try {
          await rdbStore.executeSql(`DROP TABLE IF EXISTS ${tableName}`, []);
        } catch (err) {
          hilog.error(DOMAIN, TAG, 'Failed to drop table: %{public}s', JSON.stringify(err));
        }
      }
    })

    beforeEach(() => {
      hilog.info(DOMAIN, TAG, '%{public}s', 'beforeEach');
    })

    afterEach(async () => {
      hilog.info(DOMAIN, TAG, '%{public}s', 'afterEach: cleanup test data');
      if (rdbStore) {
        try {
          const predicates = new relationalStore.RdbPredicates(tableName);
          await rdbStore.delete(predicates);
        } catch (err) {
          hilog.error(DOMAIN, TAG, 'Failed to cleanup: %{public}s', JSON.stringify(err));
        }
      }
    })

    it('testInsertAndQuery', 0, async () => {
      hilog.info(DOMAIN, TAG, '%{public}s', 'testInsertAndQuery start');
      if (!rdbStore) {
        expect(false).assertTrue();
        return;
      }

      const values: relationalStore.ValuesBucket = {
        name: 'test_name',
        value: 123,
        timestamp: Date.now()
      };

      const insertId = await rdbStore.insert(tableName, values);
      hilog.info(DOMAIN, TAG, 'Inserted id: %{public}d', insertId);
      // expect(insertId).assertGreater(0);

      const predicates = new relationalStore.RdbPredicates(tableName);
      const resultSet = await rdbStore.query(predicates, ['id', 'name', 'value', 'timestamp']);
      hilog.info(DOMAIN, TAG, 'Query result count: %{public}d', resultSet.rowCount);
      expect(resultSet.rowCount).assertEqual(1);

      resultSet.goToFirstRow();
      const name = resultSet.getString(resultSet.getColumnIndex('name'));
      const value = resultSet.getLong(resultSet.getColumnIndex('value'));
      hilog.info(DOMAIN, TAG, 'Queried name: %{public}s, value: %{public}d', name, value);

      expect(name).assertEqual('test_name');
      expect(value).assertEqual(123);

      resultSet.close();
      hilog.info(DOMAIN, TAG, '%{public}s', 'testInsertAndQuery end');
    })

    it('testBatchInsertAndQuery', 0, async () => {
      hilog.info(DOMAIN, TAG, '%{public}s', 'testBatchInsertAndQuery start');
      if (!rdbStore) {
        expect(false).assertTrue();
        return;
      }

      const valuesArray: relationalStore.ValuesBucket[] = [
        { name: 'item_1', value: 1, timestamp: Date.now() },
        { name: 'item_2', value: 2, timestamp: Date.now() },
        { name: 'item_3', value: 3, timestamp: Date.now() }
      ];

      const batchInsertCount = await rdbStore.batchInsert(tableName, valuesArray);
      hilog.info(DOMAIN, TAG, 'Batch inserted count: %{public}d', batchInsertCount);
      expect(batchInsertCount).assertEqual(3);

      const predicates = new relationalStore.RdbPredicates(tableName);
      const resultSet = await rdbStore.query(predicates, ['id', 'name', 'value']);
      hilog.info(DOMAIN, TAG, 'Query result count: %{public}d', resultSet.rowCount);
      expect(resultSet.rowCount).assertEqual(3);

      let count = 0;
      while (resultSet.goToNextRow()) {
        count++;
        const name = resultSet.getString(resultSet.getColumnIndex('name'));
        const value = resultSet.getLong(resultSet.getColumnIndex('value'));
        hilog.info(DOMAIN, TAG, 'Row %{public}d: name=%{public}s, value=%{public}d', count, name, value);
      }
      expect(count).assertEqual(3);

      resultSet.close();
      hilog.info(DOMAIN, TAG, '%{public}s', 'testBatchInsertAndQuery end');
    })

    it('testUpdate', 0, async () => {
      hilog.info(DOMAIN, TAG, '%{public}s', 'testUpdate start');
      if (!rdbStore) {
        expect(false).assertTrue();
        return;
      }

      const values: relationalStore.ValuesBucket = {
        name: 'original_name',
        value: 100,
        timestamp: Date.now()
      };
      const insertId = await rdbStore.insert(tableName, values);
      hilog.info(DOMAIN, TAG, 'Inserted id: %{public}d', insertId);

      const updateValues: relationalStore.ValuesBucket = {
        name: 'updated_name',
        value: 200
      };
      const predicates = new relationalStore.RdbPredicates(tableName);
      predicates.equalTo('id', insertId);
      const updatedCount = await rdbStore.update(updateValues, predicates);
      hilog.info(DOMAIN, TAG, 'Updated count: %{public}d', updatedCount);
      expect(updatedCount).assertEqual(1);

      const resultSet = await rdbStore.query(predicates, ['name', 'value']);
      resultSet.goToFirstRow();
      const name = resultSet.getString(resultSet.getColumnIndex('name'));
      const value = resultSet.getLong(resultSet.getColumnIndex('value'));
      hilog.info(DOMAIN, TAG, 'Updated name: %{public}s, value: %{public}d', name, value);

      expect(name).assertEqual('updated_name');
      expect(value).assertEqual(200);

      resultSet.close();
      hilog.info(DOMAIN, TAG, '%{public}s', 'testUpdate end');
    })

    it('testDelete', 0, async () => {
      hilog.info(DOMAIN, TAG, '%{public}s', 'testDelete start');
      if (!rdbStore) {
        expect(false).assertTrue();
        return;
      }

      const values: relationalStore.ValuesBucket = {
        name: 'to_be_deleted',
        value: 999,
        timestamp: Date.now()
      };
      const insertId = await rdbStore.insert(tableName, values);
      hilog.info(DOMAIN, TAG, 'Inserted id: %{public}d', insertId);

      let predicates = new relationalStore.RdbPredicates(tableName);
      let resultSet = await rdbStore.query(predicates, ['id']);
      expect(resultSet.rowCount).assertEqual(1);
      resultSet.close();

      predicates = new relationalStore.RdbPredicates(tableName);
      predicates.equalTo('id', insertId);
      const deletedCount = await rdbStore.delete(predicates);
      hilog.info(DOMAIN, TAG, 'Deleted count: %{public}d', deletedCount);
      expect(deletedCount).assertEqual(1);

      resultSet = await rdbStore.query(predicates, ['id']);
      expect(resultSet.rowCount).assertEqual(0);
      resultSet.close();

      hilog.info(DOMAIN, TAG, '%{public}s', 'testDelete end');
    })
  })
}
