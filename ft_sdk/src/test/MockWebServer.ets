/**
 * Mock HTTP Web Server for testing
 * Reference: com.google.mockwebserver.MockWebServer (Android SDK)
 *
 * Note: Due to HarmonyOS test environment limitations,
 * this is a simplified implementation that returns mock responses directly.
 *
 * @author FT SDK Team
 */

import { MockResponse } from './MockResponse';

export class MockWebServer {
  private port: number = 0;
  private isRunning: boolean = false;
  private responseQueue: MockResponse[] = [];
  private serverIp: string = "127.0.0.1";

  /**
   * Create a new MockWebServer instance
   */
  constructor() {
    // Initialize with default port
    this.port = 8080;
  }

  /**
   * Add a mock response to the queue
   * @param response MockResponse to enqueue
   */
  enqueue(response: MockResponse): void {
    this.responseQueue.push(response);
  }

  /**
   * Get the port number the server is listening on
   * @returns Port number
   */
  getPort(): number {
    return this.port;
  }

  /**
   * Get the server IP address
   * @returns Server IP address
   */
  getServerIp(): string {
    return this.serverIp;
  }

  /**
   * Start the mock server
   * Note: In HarmonyOS test environment, this just sets the running flag
   * @returns Promise that resolves when server is started
   */
  async play(): Promise<void> {
    if (this.isRunning) {
      console.warn("[MockWebServer] Server is already running");
      return;
    }

    this.isRunning = true;
    console.info(`[MockWebServer] Mock server started on ${this.serverIp}:${this.port}`);
  }

  /**
   * Stop the mock server
   * @returns Promise that resolves when server is stopped
   */
  async shutdown(): Promise<void> {
    if (!this.isRunning) {
      console.warn("[MockWebServer] Server is not running");
      return;
    }

    this.isRunning = false;
    this.port = 0;
    this.responseQueue = [];
    console.info("[MockWebServer] Server stopped");
  }

  /**
   * Get the next mock response from queue
   * @returns Next MockResponse or null if queue is empty
   */
  getNextResponse(): MockResponse | null {
    return this.responseQueue.length > 0 ? this.responseQueue.shift() as MockResponse : null;
  }

  /**
   * Check if server is running
   * @returns true if server is running
   */
  isActive(): boolean {
    return this.isRunning;
  }

  /**
   * Get response queue size
   * @returns Number of responses in queue
   */
  getQueueSize(): number {
    return this.responseQueue.length;
  }
}
