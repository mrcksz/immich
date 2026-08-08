import type { ServerConfigDto } from '@immich/sdk';
import { asUrl } from '$lib/services/shared-link.service';
import { sharedLinkFactory } from '@test-data/factories/shared-link-factory';

vi.mock(import('$lib/managers/server-config-manager.svelte'), () => ({
  serverConfigManager: {
    value: { externalDomain: 'http://localhost:2283' } as ServerConfigDto,
    init: vi.fn(),
    loadServerConfig: vi.fn(),
  },
}));

describe('SharedLinkService', () => {
  describe('asUrl', () => {
    it('should properly encode characters in slug', () => {
      expect(asUrl(sharedLinkFactory.build({ slug: 'foo/bar' }))).toBe('http://localhost:2283/s/foo%2Fbar');
    });

    it('should append the access token as a fragment', () => {
      expect(asUrl(sharedLinkFactory.build({ slug: 'wedding', accessToken: 'secret-token' }))).toBe(
        'http://localhost:2283/s/wedding#t=secret-token',
      );
    });

    it('should omit the fragment without an access token', () => {
      expect(asUrl(sharedLinkFactory.build({ slug: 'wedding', accessToken: null }))).toBe(
        'http://localhost:2283/s/wedding',
      );
    });

    it('should escape an access token containing url characters', () => {
      expect(asUrl(sharedLinkFactory.build({ slug: 'wedding', accessToken: 'a+b/c=' }))).toBe(
        'http://localhost:2283/s/wedding#t=a%2Bb%2Fc%3D',
      );
    });
  });
});
