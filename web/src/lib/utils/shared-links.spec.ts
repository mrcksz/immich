import { hasAccessToken, takeAccessToken, withAccessToken } from '$lib/utils/shared-links';

describe('shared link access tokens', () => {
  const visit = (url: string) => history.replaceState(null, '', url);

  beforeEach(() => {
    visit('/s/wedding');
  });

  describe('hasAccessToken', () => {
    it('should detect a token in the fragment', () => {
      visit('/s/wedding#t=secret-token');
      expect(hasAccessToken()).toBe(true);
    });

    it('should ignore an unrelated fragment', () => {
      visit('/s/wedding#photos');
      expect(hasAccessToken()).toBe(false);
    });

    it('should be false without a fragment', () => {
      expect(hasAccessToken()).toBe(false);
    });
  });

  describe('takeAccessToken', () => {
    it('should return the token', () => {
      visit('/s/wedding#t=secret-token');
      expect(takeAccessToken()).toBe('secret-token');
    });

    it('should strip the token from the address bar', () => {
      visit('/s/wedding#t=secret-token');
      takeAccessToken();
      expect(location.hash).toBe('');
      expect(location.pathname).toBe('/s/wedding');
    });

    it('should keep the query string intact', () => {
      visit('/s/wedding?foo=bar#t=secret-token');
      takeAccessToken();
      expect(location.search).toBe('?foo=bar');
    });

    it('should decode a token containing url characters', () => {
      visit('/s/wedding#t=a%2Bb%2Fc%3D');
      expect(takeAccessToken()).toBe('a+b/c=');
    });

    it('should return null without a token', () => {
      expect(takeAccessToken()).toBeNull();
    });

    it('should leave an unrelated fragment alone', () => {
      visit('/s/wedding#photos');
      expect(takeAccessToken()).toBeNull();
      expect(location.hash).toBe('#photos');
    });
  });

  describe('withAccessToken', () => {
    it('should round-trip through takeAccessToken', () => {
      visit(withAccessToken('/s/wedding', 'a+b/c='));
      expect(takeAccessToken()).toBe('a+b/c=');
    });
  });
});
