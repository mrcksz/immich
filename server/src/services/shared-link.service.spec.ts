import { BadRequestException, ForbiddenException, HttpException, UnauthorizedException } from '@nestjs/common';
import { AssetIdErrorReason } from 'src/dtos/asset-ids.response.dto';
import { mapSharedLink, SharedLinkEditDto } from 'src/dtos/shared-link.dto';
import { SharedLinkType } from 'src/enum';
import { SharedLinkService } from 'src/services/shared-link.service';
import { AlbumFactory } from 'test/factories/album.factory';
import { AssetFactory } from 'test/factories/asset.factory';
import { SharedLinkFactory } from 'test/factories/shared-link.factory';
import { authStub } from 'test/fixtures/auth.stub';
import { sharedLinkStub } from 'test/fixtures/shared-link.stub';
import { getForSharedLink } from 'test/mappers';
import { factory } from 'test/small.factory';
import { newTestService, ServiceMocks } from 'test/utils';

const expectStatus = async (promise: Promise<unknown>, status: number) => {
  await expect(promise).rejects.toSatisfy((error) => (error as HttpException).getStatus() === status);
};

describe(SharedLinkService.name, () => {
  let sut: SharedLinkService;
  let mocks: ServiceMocks;

  beforeEach(() => {
    ({ sut, mocks } = newTestService(SharedLinkService));
  });

  /** Stages a password protected link as the one the request authenticated against. */
  const setup = (dto: { password?: string | null; accessToken?: string | null }) => {
    const sharedLink = SharedLinkFactory.create({ password: 'password', ...dto });
    mocks.sharedLink.get.mockResolvedValue(getForSharedLink(sharedLink));
    return sharedLink;
  };

  const createWithAssets = async (dto: { password?: string | null; generateAccessToken?: boolean }) => {
    const asset = AssetFactory.create();
    const sharedLink = SharedLinkFactory.from()
      .asset(asset, (builder) => builder.exif())
      .build();
    mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set([asset.id]));
    mocks.sharedLink.create.mockResolvedValue(getForSharedLink(sharedLink));

    await sut.create(authStub.admin, { type: SharedLinkType.Individual, assetIds: [asset.id], ...dto });

    return (mocks.sharedLink.create.mock.calls.at(-1)?.[0] as { accessToken?: string | null }).accessToken;
  };

  const updateAccessToken = async (
    existing: { password?: string | null; accessToken?: string | null },
    dto: SharedLinkEditDto,
  ) => {
    const sharedLink = setup(existing);
    mocks.sharedLink.update.mockResolvedValue(getForSharedLink(sharedLink));

    await sut.update(authStub.user1, sharedLink.id, dto);

    return (mocks.sharedLink.update.mock.calls.at(-1)?.[0] as { accessToken?: string | null }).accessToken;
  };

  it('should work', () => {
    expect(sut).toBeDefined();
  });

  describe('getAll', () => {
    it('should return all shared links for a user', async () => {
      const [sharedLink1, sharedLink2] = [SharedLinkFactory.create(), SharedLinkFactory.create()];
      mocks.sharedLink.getAll.mockResolvedValue([getForSharedLink(sharedLink1), getForSharedLink(sharedLink2)]);
      await expect(sut.getAll(authStub.user1, {})).resolves.toEqual(
        [getForSharedLink(sharedLink1), getForSharedLink(sharedLink2)].map((link) =>
          mapSharedLink(link, { stripAssetMetadata: false, includeAccessToken: true }),
        ),
      );
      expect(mocks.sharedLink.getAll).toHaveBeenCalledWith({ userId: authStub.user1.user.id });
    });
  });

  describe('getMine', () => {
    it('should only work for a public user', async () => {
      await expect(sut.getMine(authStub.admin, [])).rejects.toBeInstanceOf(ForbiddenException);
      expect(mocks.sharedLink.get).not.toHaveBeenCalled();
    });

    it('should return the shared link for the public user', async () => {
      const authDto = authStub.adminSharedLink;
      const sharedLink = SharedLinkFactory.create();
      mocks.sharedLink.get.mockResolvedValue(getForSharedLink(sharedLink));
      await expect(sut.getMine(authDto, [])).resolves.toEqual(
        mapSharedLink(getForSharedLink(sharedLink), { stripAssetMetadata: false }),
      );
      expect(mocks.sharedLink.get).toHaveBeenCalledWith(authDto.user.id, authDto.sharedLink?.id);
    });

    it('should not return metadata', async () => {
      const authDto = factory.auth({
        sharedLink: {
          showExif: false,
          allowDownload: true,
          allowUpload: true,
        },
      });
      mocks.sharedLink.get.mockResolvedValue(
        getForSharedLink(
          SharedLinkFactory.from({ showExif: false })
            .asset({}, (builder) => builder.exif())
            .build(),
        ),
      );
      const response = await sut.getMine(authDto, []);
      expect(response.assets[0]).toMatchObject({ hasMetadata: false });
      expect(mocks.sharedLink.get).toHaveBeenCalledWith(authDto.user.id, authDto.sharedLink?.id);
    });

    it('should throw an error for a request without a shared link auth token', async () => {
      const authDto = authStub.adminSharedLink;
      mocks.sharedLink.get.mockResolvedValue(sharedLinkStub.passwordRequired);
      await expect(sut.getMine(authDto, [])).rejects.toBeInstanceOf(UnauthorizedException);
      expect(mocks.sharedLink.get).toHaveBeenCalledWith(authDto.user.id, authDto.sharedLink?.id);
    });

    it('should accept a valid shared link auth token', async () => {
      const sharedLink = SharedLinkFactory.create({ password: '123' });
      mocks.sharedLink.get.mockResolvedValue(getForSharedLink(sharedLink));
      const secret = Buffer.from('auth-token-123');
      mocks.crypto.hashSha256.mockReturnValue(secret);
      await expect(sut.getMine(authStub.adminSharedLink, [secret.toString('base64')])).resolves.toBeDefined();
      expect(mocks.sharedLink.get).toHaveBeenCalledWith(
        authStub.adminSharedLink.user.id,
        authStub.adminSharedLink.sharedLink?.id,
      );
    });
  });

  describe('login', () => {
    const auth = authStub.adminSharedLink;

    it('should reject a link without a password', async () => {
      setup({ password: null });
      await expect(sut.login(auth, { password: 'password' })).rejects.toBeInstanceOf(BadRequestException);
    });

    it('should require either a password or an access token', async () => {
      setup({});
      await expect(sut.login(auth, {})).rejects.toBeInstanceOf(BadRequestException);
    });

    it('should accept a valid access token', async () => {
      setup({ accessToken: 'valid-token' });
      await expect(sut.login(auth, { accessToken: 'valid-token' })).resolves.toEqual(
        expect.objectContaining({ token: expect.any(String) }),
      );
    });

    it('should not leak the access token to the visitor', async () => {
      setup({ accessToken: 'valid-token' });
      const { sharedLink } = await sut.login(auth, { accessToken: 'valid-token' });
      expect(sharedLink.accessToken).toBeUndefined();
    });

    it('should reject an invalid access token', async () => {
      setup({ accessToken: 'valid-token' });
      await expect(sut.login(auth, { accessToken: 'wrong-token' })).rejects.toBeInstanceOf(UnauthorizedException);
    });

    it('should reject an access token when the link has none', async () => {
      setup({ accessToken: null });
      await expect(sut.login(auth, { accessToken: 'any-token' })).rejects.toBeInstanceOf(UnauthorizedException);
    });

    it('should block password guessing after repeated failures', async () => {
      setup({});

      for (let i = 0; i < 10; i++) {
        await expect(sut.login(auth, { password: 'wrong' })).rejects.toBeInstanceOf(UnauthorizedException);
      }

      await expectStatus(sut.login(auth, { password: 'wrong' }), 429);
      // the correct password is refused too, otherwise the limit could be probed away
      await expectStatus(sut.login(auth, { password: 'password' }), 429);
    });

    it('should clear the failure count after a successful login', async () => {
      setup({});

      for (let i = 0; i < 9; i++) {
        await expect(sut.login(auth, { password: 'wrong' })).rejects.toBeInstanceOf(UnauthorizedException);
      }
      await expect(sut.login(auth, { password: 'password' })).resolves.toBeDefined();

      for (let i = 0; i < 9; i++) {
        await expect(sut.login(auth, { password: 'wrong' })).rejects.toBeInstanceOf(UnauthorizedException);
      }
    });

    it('should not let password failures lock out the access token', async () => {
      setup({ accessToken: 'valid-token' });

      for (let i = 0; i < 11; i++) {
        await expect(sut.login(auth, { password: 'wrong' })).rejects.toBeInstanceOf(HttpException);
      }

      await expect(sut.login(auth, { accessToken: 'valid-token' })).resolves.toBeDefined();
    });
  });

  describe('get', () => {
    it('should throw an error for an invalid shared link', async () => {
      mocks.sharedLink.get.mockResolvedValue(void 0);

      await expect(sut.get(authStub.user1, 'missing-id')).rejects.toBeInstanceOf(BadRequestException);

      expect(mocks.sharedLink.get).toHaveBeenCalledWith(authStub.user1.user.id, 'missing-id');
      expect(mocks.sharedLink.update).not.toHaveBeenCalled();
    });

    it('should get a shared link by id', async () => {
      const sharedLink = SharedLinkFactory.create();
      mocks.sharedLink.get.mockResolvedValue(getForSharedLink(sharedLink));
      await expect(sut.get(authStub.user1, sharedLink.id)).resolves.toEqual(
        mapSharedLink(getForSharedLink(sharedLink), { stripAssetMetadata: true, includeAccessToken: true }),
      );
      expect(mocks.sharedLink.get).toHaveBeenCalledWith(authStub.user1.user.id, sharedLink.id);
    });
  });

  describe('create', () => {
    it('should not allow an album shared link without an albumId', async () => {
      await expect(sut.create(authStub.admin, { type: SharedLinkType.Album, assetIds: [] })).rejects.toBeInstanceOf(
        BadRequestException,
      );
    });

    it('should not allow non-owners to create album shared links', async () => {
      await expect(
        sut.create(authStub.admin, { type: SharedLinkType.Album, assetIds: [], albumId: 'album-1' }),
      ).rejects.toBeInstanceOf(BadRequestException);
    });

    it('should not allow individual shared links with no assets', async () => {
      await expect(
        sut.create(authStub.admin, { type: SharedLinkType.Individual, assetIds: [] }),
      ).rejects.toBeInstanceOf(BadRequestException);
    });

    it('should require asset ownership to make an individual shared link', async () => {
      await expect(
        sut.create(authStub.admin, { type: SharedLinkType.Individual, assetIds: ['asset-1'] }),
      ).rejects.toBeInstanceOf(BadRequestException);
    });

    it('should create an album shared link', async () => {
      const album = AlbumFactory.from().asset().build();
      const sharedLink = SharedLinkFactory.from().album(album).build();
      mocks.access.album.checkOwnerAccess.mockResolvedValue(new Set([album.id]));
      mocks.sharedLink.create.mockResolvedValue(getForSharedLink(sharedLink));

      await sut.create(authStub.admin, { type: SharedLinkType.Album, albumId: album.id });

      expect(mocks.access.album.checkOwnerAccess).toHaveBeenCalledWith(authStub.admin.user.id, new Set([album.id]));
      expect(mocks.sharedLink.create).toHaveBeenCalledWith({
        type: SharedLinkType.Album,
        userId: authStub.admin.user.id,
        albumId: album.id,
        allowDownload: true,
        allowUpload: true,
        description: null,
        expiresAt: null,
        slug: null,
        showExif: true,
        key: Buffer.from('random-bytes', 'utf8'),
        accessToken: null,
      });
    });

    it('should create an individual shared link', async () => {
      const asset = AssetFactory.create();
      const sharedLink = SharedLinkFactory.from()
        .asset(asset, (builder) => builder.exif())
        .build();
      mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set([asset.id]));
      mocks.sharedLink.create.mockResolvedValue(getForSharedLink(sharedLink));

      await sut.create(authStub.admin, {
        type: SharedLinkType.Individual,
        assetIds: [asset.id],
        showMetadata: true,
        allowDownload: true,
        allowUpload: true,
      });

      expect(mocks.access.asset.checkOwnerAccess).toHaveBeenCalledWith(
        authStub.admin.user.id,
        new Set([asset.id]),
        false,
      );
      expect(mocks.sharedLink.create).toHaveBeenCalledWith({
        type: SharedLinkType.Individual,
        userId: authStub.admin.user.id,
        albumId: null,
        allowDownload: true,
        slug: null,
        allowUpload: true,
        assetIds: [asset.id],
        description: null,
        expiresAt: null,
        showExif: true,
        key: Buffer.from('random-bytes', 'utf8'),
        accessToken: null,
      });
    });

    it('should create a shared link with allowDownload set to false when showMetadata is false', async () => {
      const asset = AssetFactory.create();
      const sharedLink = SharedLinkFactory.from({ allowDownload: false })
        .asset(asset, (builder) => builder.exif())
        .build();
      mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set([asset.id]));
      mocks.sharedLink.create.mockResolvedValue(getForSharedLink(sharedLink));

      await sut.create(authStub.admin, {
        type: SharedLinkType.Individual,
        assetIds: [asset.id],
        showMetadata: false,
        allowDownload: true,
        allowUpload: true,
      });

      expect(mocks.access.asset.checkOwnerAccess).toHaveBeenCalledWith(
        authStub.admin.user.id,
        new Set([asset.id]),
        false,
      );
      expect(mocks.sharedLink.create).toHaveBeenCalledWith({
        type: SharedLinkType.Individual,
        userId: authStub.admin.user.id,
        albumId: null,
        allowDownload: false,
        allowUpload: true,
        assetIds: [asset.id],
        description: null,
        expiresAt: null,
        showExif: false,
        slug: null,
        key: Buffer.from('random-bytes', 'utf8'),
        accessToken: null,
      });
    });
  });

  describe('create access token', () => {
    it('should generate an access token when requested', async () => {
      await expect(createWithAssets({ password: 'password', generateAccessToken: true })).resolves.toEqual(
        expect.any(String),
      );
    });

    it('should not generate an access token by default', async () => {
      await expect(createWithAssets({ password: 'password' })).resolves.toBeNull();
    });

    it('should reject an access token without a password', async () => {
      await expect(createWithAssets({ generateAccessToken: true })).rejects.toBeInstanceOf(BadRequestException);
    });
  });

  describe('update', () => {
    it('should throw an error for an invalid shared link', async () => {
      mocks.sharedLink.get.mockResolvedValue(void 0);

      await expect(sut.update(authStub.user1, 'missing-id', {})).rejects.toBeInstanceOf(BadRequestException);

      expect(mocks.sharedLink.get).toHaveBeenCalledWith(authStub.user1.user.id, 'missing-id');
      expect(mocks.sharedLink.update).not.toHaveBeenCalled();
    });

    it('should update a shared link', async () => {
      const sharedLink = SharedLinkFactory.create();
      mocks.sharedLink.get.mockResolvedValue(getForSharedLink(sharedLink));
      mocks.sharedLink.update.mockResolvedValue(getForSharedLink(sharedLink));

      await sut.update(authStub.user1, sharedLinkStub.valid.id, { allowDownload: false });

      expect(mocks.sharedLink.get).toHaveBeenCalledWith(authStub.user1.user.id, sharedLinkStub.valid.id);
      expect(mocks.sharedLink.update).toHaveBeenCalledWith({
        id: sharedLinkStub.valid.id,
        slug: null,
        userId: authStub.user1.user.id,
        allowDownload: false,
        accessToken: undefined,
      });
    });

    it('should generate an access token on request', async () => {
      await expect(updateAccessToken({}, { generateAccessToken: true })).resolves.toEqual(expect.any(String));
    });

    it('should keep an existing access token so printed QR codes stay valid', async () => {
      await expect(updateAccessToken({ accessToken: 'existing' }, { generateAccessToken: true })).resolves.toBe(
        'existing',
      );
    });

    it('should revoke the access token on request', async () => {
      await expect(updateAccessToken({ accessToken: 'existing' }, { generateAccessToken: false })).resolves.toBeNull();
    });

    it('should reject an access token for a link without a password', async () => {
      const sharedLink = SharedLinkFactory.create({ password: null });
      mocks.sharedLink.get.mockResolvedValue(getForSharedLink(sharedLink));

      await expect(sut.update(authStub.user1, sharedLink.id, { generateAccessToken: true })).rejects.toBeInstanceOf(
        BadRequestException,
      );
    });

    it('should revoke the access token when the password is removed', async () => {
      await expect(updateAccessToken({ accessToken: 'existing' }, { password: null })).resolves.toBeNull();
    });

    it('should keep the access token when an unrelated field changes', async () => {
      await expect(updateAccessToken({ accessToken: 'existing' }, { allowDownload: false })).resolves.toBeUndefined();
    });
  });

  describe('remove', () => {
    it('should throw an error for an invalid shared link', async () => {
      mocks.sharedLink.get.mockResolvedValue(void 0);

      await expect(sut.remove(authStub.user1, 'missing-id')).rejects.toBeInstanceOf(BadRequestException);

      expect(mocks.sharedLink.get).toHaveBeenCalledWith(authStub.user1.user.id, 'missing-id');
      expect(mocks.sharedLink.update).not.toHaveBeenCalled();
    });

    it('should remove a key', async () => {
      const sharedLink = SharedLinkFactory.create();
      mocks.sharedLink.get.mockResolvedValue(getForSharedLink(sharedLink));
      mocks.sharedLink.remove.mockResolvedValue();

      await sut.remove(authStub.user1, sharedLink.id);

      expect(mocks.sharedLink.get).toHaveBeenCalledWith(authStub.user1.user.id, sharedLink.id);
      expect(mocks.sharedLink.remove).toHaveBeenCalledWith(sharedLink.id);
    });
  });

  describe('addAssets', () => {
    it('should not work on album shared links', async () => {
      const sharedLink = SharedLinkFactory.from().album().build();
      mocks.sharedLink.get.mockResolvedValue(getForSharedLink(sharedLink));

      await expect(sut.addAssets(authStub.admin, 'link-1', { assetIds: ['asset-1'] })).rejects.toBeInstanceOf(
        BadRequestException,
      );
    });

    it('should add assets to a shared link', async () => {
      const asset = AssetFactory.create();
      const sharedLink = SharedLinkFactory.from()
        .asset(asset, (builder) => builder.exif())
        .build();
      const newAsset = AssetFactory.create();
      mocks.sharedLink.get.mockResolvedValue(getForSharedLink(sharedLink));
      mocks.sharedLink.create.mockResolvedValue(getForSharedLink(sharedLink));
      mocks.sharedLink.update.mockResolvedValue(getForSharedLink(sharedLink));
      mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set([newAsset.id]));

      await expect(
        sut.addAssets(authStub.admin, sharedLink.id, { assetIds: [asset.id, 'asset-2', newAsset.id] }),
      ).resolves.toEqual([
        { assetId: asset.id, success: false, error: AssetIdErrorReason.DUPLICATE },
        { assetId: 'asset-2', success: false, error: AssetIdErrorReason.NO_PERMISSION },
        { assetId: newAsset.id, success: true },
      ]);

      expect(mocks.access.asset.checkOwnerAccess).toHaveBeenCalledTimes(1);
      expect(mocks.sharedLink.update).toHaveBeenCalled();
      expect(mocks.sharedLink.update).toHaveBeenCalledWith({
        ...getForSharedLink(sharedLink),
        slug: null,
        assetIds: [newAsset.id],
      });
    });
  });

  describe('removeAssets', () => {
    it('should not work on album shared links', async () => {
      const sharedLink = SharedLinkFactory.from().album().build();
      mocks.sharedLink.get.mockResolvedValue(getForSharedLink(sharedLink));

      await expect(sut.removeAssets(authStub.admin, sharedLink.id, { assetIds: ['asset-1'] })).rejects.toBeInstanceOf(
        BadRequestException,
      );
    });

    it('should remove assets from a shared link', async () => {
      const asset = AssetFactory.create();
      const sharedLink = SharedLinkFactory.from()
        .asset(asset, (builder) => builder.exif())
        .build();
      mocks.sharedLink.get.mockResolvedValue(getForSharedLink(sharedLink));
      mocks.sharedLink.create.mockResolvedValue(getForSharedLink(sharedLink));
      mocks.sharedLink.update.mockResolvedValue(getForSharedLink(sharedLink));
      mocks.sharedLinkAsset.remove.mockResolvedValue([asset.id]);

      await expect(
        sut.removeAssets(authStub.admin, sharedLink.id, { assetIds: [asset.id, 'asset-2'] }),
      ).resolves.toEqual([
        { assetId: asset.id, success: true },
        { assetId: 'asset-2', success: false, error: AssetIdErrorReason.NOT_FOUND },
      ]);

      expect(mocks.sharedLinkAsset.remove).toHaveBeenCalledWith(sharedLink.id, [asset.id, 'asset-2']);
      expect(mocks.sharedLink.update).toHaveBeenCalledWith(expect.objectContaining({ assets: [] }));
    });
  });

  describe('getMetadataTags', () => {
    it('should return null when auth is not a shared link', async () => {
      await expect(sut.getMetadataTags(authStub.admin)).resolves.toBe(null);

      expect(mocks.sharedLink.get).not.toHaveBeenCalled();
    });

    it('should return null when shared link has a password', async () => {
      const auth = factory.auth({ user: {}, sharedLink: { password: 'password' } });

      await expect(sut.getMetadataTags(auth)).resolves.toBe(null);

      expect(mocks.sharedLink.get).not.toHaveBeenCalled();
    });

    it('should return metadata tags', async () => {
      const sharedLink = SharedLinkFactory.from({ description: null })
        .asset({}, (builder) => builder.exif())
        .build();
      mocks.sharedLink.get.mockResolvedValue(getForSharedLink(sharedLink));

      await expect(sut.getMetadataTags(authStub.adminSharedLink)).resolves.toEqual({
        description: '1 shared photos & videos',
        imageUrl: `https://my.immich.app/api/assets/${sharedLink.assets[0].id}/thumbnail?key=${sharedLink.key.toString('base64url')}`,
        title: 'Public Share',
      });

      expect(mocks.sharedLink.get).toHaveBeenCalled();
    });

    it('should return metadata tags with a default image path if the asset id is not set', async () => {
      mocks.sharedLink.get.mockResolvedValue({ ...sharedLinkStub.individual, album: null, assets: [] });
      await expect(sut.getMetadataTags(authStub.adminSharedLink)).resolves.toEqual({
        description: '0 shared photos & videos',
        imageUrl: `https://my.immich.app/feature-panel.png`,
        title: 'Public Share',
      });

      expect(mocks.sharedLink.get).toHaveBeenCalled();
    });
  });
});
