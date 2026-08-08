import { getMySharedLink, isHttpError } from '@immich/sdk';
import { getAssetMediaUrl, getSharedLink as getCachedSharedLink, setSharedLink } from '$lib/utils';
import { authenticate } from '$lib/utils/auth';
import { getFormatter } from '$lib/utils/i18n';
import { getAssetInfoFromParam } from '$lib/utils/navigation';

/**
 * Access tokens travel in the URL fragment rather than the query string, because browsers never
 * send fragments to the server. That keeps a printed QR code out of access logs and referrer
 * headers while still unlocking a password protected link.
 */
const ACCESS_TOKEN_FRAGMENT = 't';

const readAccessToken = () => {
  if (globalThis.window === undefined) {
    return null;
  }

  return new URLSearchParams(location.hash.slice(1)).get(ACCESS_TOKEN_FRAGMENT);
};

export const hasAccessToken = () => readAccessToken() !== null;

/** Reads the token and strips it from the address bar, so it does not linger in history or bookmarks. */
export const takeAccessToken = () => {
  const accessToken = readAccessToken();
  if (accessToken !== null) {
    const { pathname, search } = location;
    history.replaceState(history.state, '', pathname + search);
  }

  return accessToken;
};

export const withAccessToken = (url: string, accessToken: string) =>
  `${url}#${new URLSearchParams({ [ACCESS_TOKEN_FRAGMENT]: accessToken })}`;

export const asQueryString = ({ slug, key }: { slug?: string; key?: string }) => {
  const params = new URLSearchParams();
  if (slug) {
    params.set('slug', slug);
  }

  if (key) {
    params.set('key', key);
  }

  return params.toString();
};

export const loadSharedLink = async ({
  url,
  params,
}: {
  url: URL;
  params: { key?: string; slug?: string; assetId?: string };
}) => {
  const { key, slug } = params;
  await authenticate(url, { public: true });

  const common = { key, slug };
  const $t = await getFormatter();

  const cachedSharedLink = getCachedSharedLink();
  const sharedLinkPromise =
    cachedSharedLink && (key === cachedSharedLink.key || slug === cachedSharedLink.slug)
      ? Promise.resolve(cachedSharedLink)
      : getMySharedLink({ key, slug });

  try {
    const [sharedLink, asset] = await Promise.all([sharedLinkPromise, getAssetInfoFromParam(params)]);
    setSharedLink(sharedLink);
    const assetCount = sharedLink.assets.length;
    const assetId = sharedLink.album?.albumThumbnailAssetId || sharedLink.assets[0]?.id;
    const assetPath = assetId ? getAssetMediaUrl({ id: assetId }) : '/feature-panel.png';

    return {
      ...common,
      sharedLink,
      asset,
      meta: {
        title: sharedLink.album ? sharedLink.album.albumName : $t('public_share'),
        description: sharedLink.description || $t('shared_photos_and_videos_count', { values: { assetCount } }),
        imageUrl: assetPath,
      },
    };
  } catch (error) {
    if (isHttpError(error) && error.data.message === 'Password required') {
      return {
        ...common,
        passwordRequired: true,
        meta: {
          title: $t('password_required'),
        },
      };
    }

    throw error;
  }
};
