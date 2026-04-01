/**
 * Web JS method registration interface
 * Defines the interface for communication between Web and Native
 * 
 * Based on Android SDK's WebAppInterface.java
 */
export interface JsReceiver {
  /**
   * Send event to native without callback
   * @param event Event data as JSON string
   */
  sendEvent(event: string): void;

  /**
   * Send event to native with callback method
   * @param event Event data as JSON string
   * @param callbackMethod Method name to call back
   */
  sendEventWithCallback(event: string, callbackMethod: string): void;

  /**
   * Add event listener for Web events
   * @param event Event type
   * @param callbackMethod Callback method name
   */
  addEventListener(event: string, callbackMethod: string): void;
}

