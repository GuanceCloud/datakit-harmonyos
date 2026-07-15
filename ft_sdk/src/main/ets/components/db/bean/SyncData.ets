/**
 * HarmonyOS SDK Synchronization Data Model Class
 */
import { DataType } from '../../enum/Enums';
import { Utils } from '../../utils';

/**
 * SyncData JSON Interface
 */
export interface SyncDataJSON {
  id: number;
  dataType: DataType;
  dataString: string;
  uuid: string;
  time: number;
  customDataTypeString?: string;
}

/**
 * Synchronization Data Model
 * Used to store data that needs to be synchronized to the server
 */
export class SyncData {
  /**
   * Synchronization data unique ID, assigned only during sync upload
   */
  private id: number = 0;

  /**
   * Synchronization data type
   */
  private dataType: DataType;

  /**
   * Custom data type string (for error_sampled types)
   */
  private customDataTypeString?: string;

  /**
   * Synchronization data string, old data is JSON, new data is line protocol
   */
  private dataString: string = "";

  /**
   * Data UUID
   */
  private uuid: string = "";

  /**
   * Operation time
   */
  private time: number = 0;

  /**
   * Constructor
   * @param dataType Data type
   * Note: time should be set explicitly after construction, not in constructor.
   * This ensures timestamp is set only once when data is created, and remains immutable.
   */
  constructor(dataType: DataType) {
    this.dataType = dataType;
    // Do NOT set time here - it should be set explicitly when data is created
    // This ensures timestamp is immutable and tied to uuid creation
    this.time = 0;
    this.uuid = Utils.generateUUID();
  }

  /**
   * Get ID
   * @returns number
   */
  public getId(): number {
    return this.id;
  }

  /**
   * Set ID
   * @param id ID value
   */
  public setId(id: number): void {
    this.id = id;
  }

  /**
   * Get data type
   * @returns DataType
   */
  public getDataType(): DataType {
    return this.dataType;
  }

  /**
   * Get data type as string (for error_sampled types)
   * @returns string
   */
  public getDataTypeString(): string {
    return this.dataType.toString();
  }

  /**
   * Set custom data type string (for error_sampled types)
   * This allows storing data with custom type strings like "rum_app_error_sampled"
   * @param dataTypeString Custom data type string
   */
  public setCustomDataTypeString(dataTypeString: string): void {
    this.customDataTypeString = dataTypeString;
  }

  /**
   * Get custom data type string if set
   * @returns string | undefined
   */
  public getCustomDataTypeString(): string | undefined {
    return this.customDataTypeString;
  }

  /**
   * Get data string
   * @returns string
   */
  public getDataString(): string {
    return this.dataString;
  }

  /**
   * Set data string
   * @param dataString Data string
   */
  public setDataString(dataString: string): void {
    this.dataString = dataString;
  }

  /**
   * Get UUID
   * @returns string
   */
  public getUuid(): string {
    return this.uuid;
  }

  /**
   * Set UUID
   * @param uuid UUID value
   */
  public setUuid(uuid: string): void {
    this.uuid = uuid;
  }

  /**
   * Get time
   * @returns number
   */
  public getTime(): number {
    return this.time;
  }

  /**
   * Set time
   * @param time Timestamp
   */
  public setTime(time: number): void {
    this.time = time;
  }


  /**
   * Mark package sequence ID, replace uuid with packageId.uuid in sdk_data_id tag
   * Android: dataString = dataString.replaceFirst(uuid, packageId + "." + uuid);
   * This replaces the uuid in sdk_data_id tag, changing:
   * sdk_data_id=abc123 -> sdk_data_id=1_2_3.abc123
   * Used for data tracking and batch identification
   * @param packageId Package ID (format: {seq}_{pid}_{count})
   * @returns string Modified line protocol data with package ID
   */
  public getLineProtocolDataWithPkgId(packageId: string): string {
    if (!this.dataString || !packageId) {
      return this.dataString || "";
    }
    // Replace the first occurrence of uuid with packageId.uuid
    // This is done to mark the data with package ID for tracking
    return this.dataString.replace(this.uuid, `${packageId}.${this.uuid}`);
  }

  /**
   * Clone object
   * @returns SyncData
   */
  public clone(): SyncData {
    const cloned = new SyncData(this.dataType);
    cloned.id = this.id;
    cloned.dataString = this.dataString;
    cloned.uuid = this.uuid;
    cloned.time = this.time;
    cloned.customDataTypeString = this.customDataTypeString;
    return cloned;
  }

  /**
   * Convert to string
   * @returns string
   */
  public toString(): string {
    return `SyncData{id=${this.id}, dataType=${this.dataType}, dataString='${this.dataString}', time=${this.time}}`;
  }

  /**
   * Convert to JSON object
   * @returns SyncDataJSON
   */
  public toJSON(): SyncDataJSON {
    return {
      id: this.id,
      dataType: this.dataType,
      dataString: this.dataString,
      uuid: this.uuid,
      time: this.time,
      customDataTypeString: this.customDataTypeString
    };
  }

  /**
   * Create SyncData from JSON object
   * @param json JSON object
   * @returns SyncData
   */
  public static fromJSON(json: SyncDataJSON): SyncData {
    const syncData = new SyncData(json.dataType);
    syncData.id = json.id || 0;
    syncData.dataString = json.dataString || "";
    syncData.uuid = json.uuid || "";
    syncData.time = json.time || Date.now();
    if (json.customDataTypeString && json.customDataTypeString.length > 0) {
      syncData.customDataTypeString = json.customDataTypeString;
    }
    return syncData;
  }

  /**
   * Validate data integrity
   * @returns boolean
   */
  public isValid(): boolean {
    return this.dataType !== undefined && 
           this.dataString !== undefined && 
           this.dataString.length > 0 &&
           this.uuid !== undefined && 
           this.uuid.length > 0 &&
           this.time > 0;
  }

  /**
   * Reset data
   */
  public reset(): void {
    this.id = 0;
    this.dataString = "";
    this.uuid = "";
    this.time = Date.now();
  }
}
