import userEvent from '@testing-library/user-event';
import { renderWithTooltips } from '$tests/helpers';
import SharedLinkFormFields from './SharedLinkFormFields.svelte';

describe('SharedLinkFormFields component', () => {
  const isChecked = (element: Element) =>
    element instanceof HTMLInputElement ? element.checked : element.getAttribute('aria-checked') === 'true';

  const render = (props: Partial<Record<string, unknown>> = {}) => {
    const { container } = renderWithTooltips(SharedLinkFormFields, {
      slug: '',
      password: '',
      description: '',
      allowDownload: true,
      allowUpload: false,
      showMetadata: true,
      expiresAt: null,
      generateAccessToken: false,
      ...props,
    });

    // in DOM order: access token, metadata, download, upload
    const switches = Array.from(container.querySelectorAll('[role="switch"], input[type="checkbox"]'));
    expect(switches).toHaveLength(4);

    const [generateAccessToken, showMetadata, allowDownload, allowUpload] = switches;
    return { container, generateAccessToken, showMetadata, allowDownload, allowUpload };
  };

  it('turns downloads off when metadata is disabled', async () => {
    const { showMetadata, allowDownload } = render();
    const user = userEvent.setup();

    expect(isChecked(allowDownload)).toBe(true);

    await user.click(showMetadata);

    expect(isChecked(showMetadata)).toBe(false);
    expect(isChecked(allowDownload)).toBe(false);
  });

  it('keeps the access token switch off without a password', () => {
    const { generateAccessToken } = render({ generateAccessToken: true });

    expect(isChecked(generateAccessToken)).toBe(false);
  });

  it('allows an access token once a password is set', () => {
    const { generateAccessToken } = render({ password: 'secret', generateAccessToken: true });

    expect(isChecked(generateAccessToken)).toBe(true);
  });

  it('revokes the access token when the password is cleared', async () => {
    const { container, generateAccessToken } = render({ password: 'secret', generateAccessToken: true });
    const user = userEvent.setup();

    const passwordInput = container.querySelector('input[type="password"]');
    expect(passwordInput).not.toBeNull();

    await user.clear(passwordInput!);

    expect(isChecked(generateAccessToken)).toBe(false);
  });
});
