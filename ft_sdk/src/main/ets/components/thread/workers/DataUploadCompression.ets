import { util } from '@kit.ArkTS';
import zlib from '@ohos.zlib';

export interface DataUploadPayloadCompressor {
  compress(body: string): Promise<ArrayBuffer>;
}

export interface DataUploadPreparedPayload {
  compressedBody?: ArrayBuffer;
  contentEncoding?: string;
}

class ZlibDeflatePayloadCompressor implements DataUploadPayloadCompressor {
  async compress(body: string): Promise<ArrayBuffer> {
    const sourceBytes = util.TextEncoder.create('utf-8').encodeInto(body);
    const source = new ArrayBuffer(sourceBytes.byteLength);
    new Uint8Array(source).set(sourceBytes);

    const zip = await zlib.createZip();
    const destinationLength = await zip.compressBound(sourceBytes.byteLength);
    if (destinationLength <= 0) {
      throw new Error(`Invalid deflate destination length: ${destinationLength}`);
    }

    const destination = new ArrayBuffer(destinationLength);
    const output = await zip.compress(destination, source, sourceBytes.byteLength);
    if (output.status !== zlib.ReturnStatus.OK || output.destLen <= 0 || output.destLen > destination.byteLength) {
      throw new Error(`Deflate compression failed: status=${output.status}, length=${output.destLen}`);
    }

    return destination.slice(0, output.destLen);
  }
}

let payloadCompressor: DataUploadPayloadCompressor = new ZlibDeflatePayloadCompressor();

/**
 * Prepares the binary body and the associated HTTP content encoding. A compression failure intentionally
 * returns an empty payload so callers safely continue with the original text body and no encoding header.
 */
export async function prepareDataUploadPayload(
  body: string,
  compressIntakeRequests: boolean
): Promise<DataUploadPreparedPayload> {
  if (!compressIntakeRequests || body.length === 0) {
    return {};
  }

  try {
    return {
      compressedBody: await payloadCompressor.compress(body),
      contentEncoding: 'deflate'
    };
  } catch (_) {
    return {};
  }
}

/** Internal test seam for validating the plaintext fallback path. */
export function setDataUploadPayloadCompressorInternal(compressor: DataUploadPayloadCompressor | null): void {
  payloadCompressor = compressor ?? new ZlibDeflatePayloadCompressor();
}

export function resetDataUploadPayloadCompressorInternal(): void {
  payloadCompressor = new ZlibDeflatePayloadCompressor();
}
