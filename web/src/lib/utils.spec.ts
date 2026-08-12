import { AssetTypeEnum } from '@immich/sdk';
import { getAssetUrl, semverToName, shareFile } from '$lib/utils';
import { assetFactory } from '@test-data/factories/asset-factory';
import { sharedLinkFactory } from '@test-data/factories/shared-link-factory';

describe('utils', () => {
  describe(getAssetUrl.name, () => {
    it('should return thumbnail URL for static images', () => {
      const asset = assetFactory.build({
        originalPath: 'image.jpg',
        originalMimeType: 'image/jpeg',
        type: AssetTypeEnum.Image,
      });

      const url = getAssetUrl({ asset });

      // Should return a thumbnail URL (contains /thumbnail)
      expect(url).toContain('/thumbnail');
      expect(url).toContain(asset.id);
    });

    it('should return thumbnail URL for static gifs', () => {
      const asset = assetFactory.build({
        originalPath: 'image.gif',
        originalMimeType: 'image/gif',
        type: AssetTypeEnum.Image,
      });

      const url = getAssetUrl({ asset });

      expect(url).toContain('/thumbnail');
      expect(url).toContain(asset.id);
    });

    it('should return thumbnail URL for static webp images', () => {
      const asset = assetFactory.build({
        originalPath: 'image.webp',
        originalMimeType: 'image/webp',
        type: AssetTypeEnum.Image,
      });

      const url = getAssetUrl({ asset });

      expect(url).toContain('/thumbnail');
      expect(url).toContain(asset.id);
    });

    it('should return original URL for animated gifs', () => {
      const asset = assetFactory.build({
        originalPath: 'image.gif',
        originalMimeType: 'image/gif',
        type: AssetTypeEnum.Image,
        duration: 2000,
      });

      const url = getAssetUrl({ asset });

      // Should return original URL (contains /original)
      expect(url).toContain('/original');
      expect(url).toContain(asset.id);
    });

    it('should return original URL for animated webp images', () => {
      const asset = assetFactory.build({
        originalPath: 'image.webp',
        originalMimeType: 'image/webp',
        type: AssetTypeEnum.Image,
        duration: 2000,
      });

      const url = getAssetUrl({ asset });

      expect(url).toContain('/original');
      expect(url).toContain(asset.id);
    });

    it('should return original URL for video assets with forceOriginal', () => {
      const asset = assetFactory.build({
        originalPath: 'video.mp4',
        originalMimeType: 'video/mp4',
        type: AssetTypeEnum.Video,
      });

      const url = getAssetUrl({ asset, forceOriginal: true });

      expect(url).toContain('/original');
      expect(url).toContain(asset.id);
    });

    it('should return thumbnail URL for video assets without forceOriginal', () => {
      const asset = assetFactory.build({
        originalPath: 'video.mp4',
        originalMimeType: 'video/mp4',
        type: AssetTypeEnum.Video,
      });

      const url = getAssetUrl({ asset });

      expect(url).toContain('/thumbnail');
      expect(url).toContain(asset.id);
    });

    it('should return thumbnail URL for static images in shared link even with download and showMetadata permissions', () => {
      const asset = assetFactory.build({
        originalPath: 'image.gif',
        originalMimeType: 'image/gif',
        type: AssetTypeEnum.Image,
      });
      const sharedLink = sharedLinkFactory.build({ allowDownload: true, showMetadata: true, assets: [asset] });

      const url = getAssetUrl({ asset, sharedLink });

      expect(url).toContain('/thumbnail');
      expect(url).toContain(asset.id);
    });

    it('should return original URL for animated images in shared link with download and showMetadata permissions', () => {
      const asset = assetFactory.build({
        originalPath: 'image.gif',
        originalMimeType: 'image/gif',
        type: AssetTypeEnum.Image,
        duration: 2000,
      });
      const sharedLink = sharedLinkFactory.build({ allowDownload: true, showMetadata: true, assets: [asset] });

      const url = getAssetUrl({ asset, sharedLink });

      expect(url).toContain('/original');
      expect(url).toContain(asset.id);
    });

    it('should return thumbnail URL (not original) for animated images when shared link download permission is false', () => {
      const asset = assetFactory.build({
        originalPath: 'image.gif',
        originalMimeType: 'image/gif',
        type: AssetTypeEnum.Image,
        duration: 2000,
      });
      const sharedLink = sharedLinkFactory.build({ allowDownload: false, assets: [asset] });

      const url = getAssetUrl({ asset, sharedLink });

      expect(url).toContain('/thumbnail');
      expect(url).not.toContain('/original');
      expect(url).toContain(asset.id);
    });

    it('should return thumbnail URL (not original) for animated images when shared link showMetadata permission is false', () => {
      const asset = assetFactory.build({
        originalPath: 'image.gif',
        originalMimeType: 'image/gif',
        type: AssetTypeEnum.Image,
        duration: 2000,
      });
      const sharedLink = sharedLinkFactory.build({ showMetadata: false, assets: [asset] });

      const url = getAssetUrl({ asset, sharedLink });

      expect(url).toContain('/thumbnail');
      expect(url).not.toContain('/original');
      expect(url).toContain(asset.id);
    });
  });
  describe('semverToName', () => {
    it('should not append release candidate tag if prelease is not set', () => {
      expect(semverToName({ major: 3, minor: 0, patch: 0, prerelease: null })).toEqual('v3.0.0');
    });

    it('should append release candidate if set', () => {
      expect(semverToName({ major: 3, minor: 0, patch: 0, prerelease: 0 })).toEqual('v3.0.0-rc.0');
    });
  });
  describe(shareFile.name, () => {
    const originalFetch = globalThis.fetch;
    const originalNavigator = globalThis.navigator;

    const mockNavigator = (overrides: Partial<Navigator>) => {
      Object.defineProperty(globalThis, 'navigator', { value: overrides, configurable: true });
    };

    afterEach(() => {
      globalThis.fetch = originalFetch;
      Object.defineProperty(globalThis, 'navigator', { value: originalNavigator, configurable: true });
    });

    const mockFetch = (ok: boolean, type = 'image/jpeg') => {
      globalThis.fetch = vi.fn().mockResolvedValue({
        ok,
        status: ok ? 200 : 404,
        blob: () => Promise.resolve(new Blob(['data'], { type })),
      }) as unknown as typeof fetch;
    };

    it('should pass the fetched file to the share sheet', async () => {
      mockFetch(true);
      const share = vi.fn().mockResolvedValue(undefined);
      mockNavigator({ canShare: () => true, share } as unknown as Navigator);

      await expect(shareFile('/api/assets/1/original', 'beach.jpg')).resolves.toBe(true);

      const [{ files }] = share.mock.calls[0];
      expect(files[0].name).toBe('beach.jpg');
      expect(files[0].type).toBe('image/jpeg');
    });

    it('should not share when the file type is rejected', async () => {
      mockFetch(true);
      const share = vi.fn();
      mockNavigator({ canShare: () => false, share } as unknown as Navigator);

      await expect(shareFile('/api/assets/1/original', 'beach.jpg')).resolves.toBe(false);
      expect(share).not.toHaveBeenCalled();
    });

    it('should throw when the file cannot be fetched', async () => {
      mockFetch(false);
      mockNavigator({ canShare: () => true, share: vi.fn() } as unknown as Navigator);

      await expect(shareFile('/api/assets/1/original', 'beach.jpg')).rejects.toThrow('404');
    });

    it('should propagate a dismissed share sheet', async () => {
      mockFetch(true);
      const abort = Object.assign(new Error('dismissed'), { name: 'AbortError' });
      mockNavigator({ canShare: () => true, share: vi.fn().mockRejectedValue(abort) } as unknown as Navigator);

      await expect(shareFile('/api/assets/1/original', 'beach.jpg')).rejects.toMatchObject({ name: 'AbortError' });
    });
  });
});
