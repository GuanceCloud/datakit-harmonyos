/**
 * Mock HTTP response for testing
 * Reference: com.google.mockwebserver.MockResponse (Android SDK)
 *
 * @author FT SDK Team
 */

export class MockResponse {
  private responseBody: string = "";
  private responseCode: number = 200;

  /**
   * Set the response body
   * @param body Response body content
   * @returns this MockResponse instance for chaining
   */
  setBody(body: string): MockResponse {
    this.responseBody = body;
    return this;
  }

  /**
   * Get the response body
   * @returns Response body content
   */
  getBody(): string {
    return this.responseBody;
  }

  /**
   * Set the HTTP response code
   * @param code HTTP response code (e.g., 200, 400, 500)
   * @returns this MockResponse instance for chaining
   */
  setResponseCode(code: number): MockResponse {
    this.responseCode = code;
    return this;
  }

  /**
   * Get the HTTP response code
   * @returns HTTP response code
   */
  getResponseCode(): number {
    return this.responseCode;
  }

  /**
   * Build HTTP response string
   * @returns Complete HTTP response as string
   */
  toHttpResponse(): string {
    const statusText = this.getStatusText(this.responseCode);
    let response = `HTTP/1.1 ${this.responseCode} ${statusText}\r\n`;
    response += "Content-Type: application/json\r\n";
    response += "Content-Length: " + this.responseBody.length + "\r\n";
    response += "Connection: close\r\n";
    response += "\r\n";
    response += this.responseBody;
    return response;
  }

  /**
   * Get HTTP status text for status code
   * @param code HTTP status code
   * @returns Status text (e.g., "OK", "Bad Request")
   */
  private getStatusText(code: number): string {
    switch (code) {
      case 200:
        return "OK";
      case 400:
        return "Bad Request";
      case 401:
        return "Unauthorized";
      case 403:
        return "Forbidden";
      case 404:
        return "Not Found";
      case 500:
        return "Internal Server Error";
      case 502:
        return "Bad Gateway";
      case 503:
        return "Service Unavailable";
      default:
        return "Unknown";
    }
  }
}
