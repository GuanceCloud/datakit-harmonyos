import { rcp } from '@kit.RemoteCommunicationKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@ohos.base';
import { createDefaultFTSessionConfiguration } from 'shareLibrary/src/main/ets/components/network/FTHttpAutoTrack';
import { DemoLogger } from '../utils/DemoLogger';

const TAG = "NetworkImage";

/**
 * Image cache to avoid re-downloading the same URL
 * Key: image URL, Value: PixelMap
 */
const imageCache: Map<string, image.PixelMap> = new Map();
const loadingPromises: Map<string, Promise<image.PixelMap>> = new Map();

/**
 * Image cache manager
 * Provides methods to manage the image cache
 */
export class NetworkImageCache {
  /**
   * Clear all cached images
   */
  public static clearAll(): void {
    const cacheSize = imageCache.size;
    imageCache.clear();
    loadingPromises.clear();
    DemoLogger.i(TAG, `Cleared all image cache (${cacheSize} images)`);
  }

  /**
   * Clear cache for a specific image URL
   * @param url Image URL to clear from cache
   */
  public static clear(url: string): void {
    if (imageCache.has(url)) {
      imageCache.delete(url);
      DemoLogger.i(TAG, `Cleared cache for image: ${url}`);
    } else {
      DemoLogger.i(TAG, `Image not found in cache: ${url}`);
    }
    // Also clear loading promise if exists
    if (loadingPromises.has(url)) {
      loadingPromises.delete(url);
    }
  }

  /**
   * Get cache size
   * @returns Number of cached images
   */
  public static getCacheSize(): number {
    return imageCache.size;
  }

  /**
   * Check if an image URL is cached
   * @param url Image URL to check
   * @returns true if the image is cached
   */
  public static isCached(url: string): boolean {
    return imageCache.has(url);
  }
}

/**
 * Network Image Component
 * A custom Image component that loads images from network URLs
 * and supports monitoring through RCP (Resource) tracking
 * 
 * Usage:
 * NetworkImage({ src: 'https://example.com/image.jpg' })
 *   .id('my-image')
 *   .width(100)
 *   .height(100)
 *   .onClick(() => {})
 */
@Component
export struct NetworkImage {
  @Prop src: string = '';

  @State imageData: image.PixelMap | null = null;
  @State isLoading: boolean = false;
  @State loadError: boolean = false;

  /**
   * Load image from network URL using RCP with caching
   */
  private async loadImage(): Promise<void> {
    if (!this.src || this.src.trim().length === 0) {
      DemoLogger.w(TAG, "Image URL is empty");
      return;
    }

    // Check cache first
    const cachedPixelMap = imageCache.get(this.src);
    if (cachedPixelMap) {
      DemoLogger.i(TAG, `Using cached image for: ${this.src}`);
      this.imageData = cachedPixelMap;
      this.isLoading = false;
      this.loadError = false;
      return;
    }

    // Check if already loading this URL
    const existingPromise = loadingPromises.get(this.src);
    if (existingPromise) {
      DemoLogger.i(TAG, `Image already loading, waiting for existing request: ${this.src}`);
      this.isLoading = true;
      this.loadError = false;
      try {
        const pixelMap = await existingPromise;
        this.imageData = pixelMap;
        this.isLoading = false;
      } catch (error) {
        DemoLogger.e(TAG, `Error waiting for existing image load: ${error}`);
        this.loadError = true;
        this.isLoading = false;
      }
      return;
    }

    this.isLoading = true;
    this.loadError = false;

    // Create loading promise
    const loadPromise = this.fetchAndCacheImage();
    loadingPromises.set(this.src, loadPromise);

    try {
      const pixelMap = await loadPromise;
      this.imageData = pixelMap;
      this.isLoading = false;
    } catch (error) {
      this.loadError = true;
      this.isLoading = false;
    } finally {
      loadingPromises.delete(this.src);
    }
  }

  /**
   * Fetch image from network and cache it
   */
  private async fetchAndCacheImage(): Promise<image.PixelMap> {
    const session = rcp.createSession(createDefaultFTSessionConfiguration());

    const startTime = Date.now();
    DemoLogger.i(TAG, `Starting to load image from: ${this.src} using RCP`);

    const request = new rcp.Request(this.src, 'GET');
    const response = await session.fetch(request);

    const loadTime = Date.now() - startTime;

    if (response.statusCode < 200 || response.statusCode >= 300) {
      const error = `Failed to load image: HTTP ${response.statusCode}`;
      DemoLogger.e(TAG, error);
      throw new Error(error);
    }

    const arrayBuffer = response.body as ArrayBuffer;
    if (!arrayBuffer) {
      const error = "Response body is not ArrayBuffer";
      DemoLogger.e(TAG, error);
      throw new Error(error);
    }

    const responseSize = arrayBuffer.byteLength;
    DemoLogger.i(TAG, `Image loaded successfully via RCP. Size: ${responseSize} bytes, Time: ${loadTime}ms`);

    const imageSource = image.createImageSource(arrayBuffer);
    const pixelMap = await imageSource.createPixelMap();

    // Cache the PixelMap
    imageCache.set(this.src, pixelMap);
    DemoLogger.i(TAG, `Image cached for: ${this.src}`);

    pixelMap.getImageInfo().then((imageInfo: image.ImageInfo) => {
      DemoLogger.i(TAG, `PixelMap created successfully. Image dimensions: ${imageInfo.size.width}x${imageInfo.size.height}`);
    }).catch((error: BusinessError) => {
      DemoLogger.w(TAG, `Failed to get image info: ${error.message}`);
    });

    return pixelMap;
  }

  aboutToDisappear(): void {
    // Session is created per request, no cleanup needed here
  }

  aboutToAppear(): void {
    if (this.src && this.src.trim().length > 0) {
      this.loadImage();
    }
  }

  build() {
    if (this.imageData) {
      Image(this.imageData)
        .customProperty('__component_type__', 'Image')
    } else if (this.isLoading) {
      Image($r('app.media.startIcon'))
        .opacity(0.5)
        .customProperty('__component_type__', 'Image')
    } else if (this.loadError) {
      Image($r('app.media.startIcon'))
        .opacity(0.3)
        .customProperty('__component_type__', 'Image')
    } else {
      Image($r('app.media.startIcon'))
        .customProperty('__component_type__', 'Image')
    }
  }
}
