import { HttpBuilder, HttpPayloadCompressor } from '../../http/HttpBuilder';

export class HttpInternalTestAccess {
  public static setPayloadCompressor(compressor: HttpPayloadCompressor | null): void {
    HttpBuilder.setPayloadCompressorInternal(compressor);
  }

  public static resetPayloadCompressor(): void {
    HttpBuilder.resetPayloadCompressorInternal();
  }
}
