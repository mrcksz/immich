import {
  BadRequestException,
  ForbiddenException,
  HttpException,
  HttpStatus,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { PostgresError } from 'postgres';
import { SharedLink } from 'src/database';
import { AssetIdErrorReason, AssetIdsResponseDto } from 'src/dtos/asset-ids.response.dto';
import { AssetIdsDto } from 'src/dtos/asset.dto';
import { AuthDto } from 'src/dtos/auth.dto';
import {
  mapSharedLink,
  SharedLinkCreateDto,
  SharedLinkEditDto,
  SharedLinkLoginDto,
  SharedLinkResponseDto,
  SharedLinkSearchDto,
} from 'src/dtos/shared-link.dto';
import { Permission, SharedLinkType } from 'src/enum';
import { BaseService } from 'src/services/base.service';
import { getExternalDomain, OpenGraphTags } from 'src/utils/misc';
import { AttemptLimiter } from 'src/utils/rate-limit';

const ACCESS_TOKEN_BYTES = 24;

@Injectable()
export class SharedLinkService extends BaseService {
  /** Passwords are user chosen and therefore guessable, so failures are capped tightly. */
  private passwordLimiter = new AttemptLimiter(10, 15 * 60 * 1000);

  /**
   * Access tokens carry 192 bits of entropy and cannot realistically be guessed. This limit only
   * exists so a flood of bogus tokens cannot be used to hammer the database.
   */
  private accessTokenLimiter = new AttemptLimiter(60, 60 * 1000);

  async getAll(auth: AuthDto, { id, albumId }: SharedLinkSearchDto): Promise<SharedLinkResponseDto[]> {
    return this.sharedLinkRepository
      .getAll({ userId: auth.user.id, id, albumId })

      .then((links) =>
        links.map((link) => mapSharedLink(link, { stripAssetMetadata: false, includeAccessToken: true })),
      );
  }

  async login(auth: AuthDto, dto: SharedLinkLoginDto) {
    if (!auth.sharedLink) {
      throw new ForbiddenException();
    }

    const sharedLink = await this.findOrFail(auth.user.id, auth.sharedLink.id);
    const { id, password, accessToken } = sharedLink;

    if (!password) {
      throw new BadRequestException('Shared link is not password protected');
    }

    if (dto.accessToken === undefined && dto.password === undefined) {
      throw new BadRequestException('A password or an access token is required');
    }

    if (dto.accessToken === undefined) {
      this.verifySecret(this.passwordLimiter, id, dto.password!, password, 'Invalid password');
    } else {
      this.verifySecret(this.accessTokenLimiter, id, dto.accessToken, accessToken, 'Invalid access token');
    }

    return {
      sharedLink: mapSharedLink(sharedLink, { stripAssetMetadata: !sharedLink.showExif }),
      token: this.asToken({ id, password }),
    };
  }

  private verifySecret(
    limiter: AttemptLimiter,
    key: string,
    provided: string,
    expected: string | null,
    message: string,
  ): void {
    const retryAfter = limiter.retryAfter(key);
    if (retryAfter > 0) {
      throw new HttpException(
        { status: HttpStatus.TOO_MANY_REQUESTS, error: 'Too many failed attempts, please try again later' },
        HttpStatus.TOO_MANY_REQUESTS,
        { description: `Retry after ${retryAfter}s` },
      );
    }

    if (!expected || !this.cryptoRepository.compareTimingSafe(provided, expected)) {
      limiter.recordFailure(key);
      throw new UnauthorizedException(message);
    }

    limiter.recordSuccess(key);
  }

  async getMine(auth: AuthDto, authTokens: string[]) {
    if (!auth.sharedLink) {
      throw new ForbiddenException();
    }

    const sharedLink = await this.findOrFail(auth.user.id, auth.sharedLink.id);
    const { id, password } = sharedLink;

    if (password && !authTokens.includes(this.asToken({ id, password }))) {
      throw new UnauthorizedException('Password required');
    }

    return mapSharedLink(sharedLink, { stripAssetMetadata: !sharedLink.showExif });
  }

  async get(auth: AuthDto, id: string): Promise<SharedLinkResponseDto> {
    const sharedLink = await this.findOrFail(auth.user.id, id);
    return mapSharedLink(sharedLink, { stripAssetMetadata: false, includeAccessToken: true });
  }

  async create(auth: AuthDto, dto: SharedLinkCreateDto): Promise<SharedLinkResponseDto> {
    switch (dto.type) {
      case SharedLinkType.Album: {
        if (!dto.albumId) {
          throw new BadRequestException('Invalid albumId');
        }
        await this.requireAccess({ auth, permission: Permission.AlbumShare, ids: [dto.albumId] });
        break;
      }

      case SharedLinkType.Individual: {
        if (!dto.assetIds || dto.assetIds.length === 0) {
          throw new BadRequestException('Invalid assetIds');
        }

        await this.requireAccess({ auth, permission: Permission.AssetShare, ids: dto.assetIds });

        break;
      }
    }

    try {
      const sharedLink = await this.sharedLinkRepository.create({
        key: this.cryptoRepository.randomBytes(50),
        userId: auth.user.id,
        type: dto.type,
        albumId: dto.albumId || null,
        assetIds: dto.assetIds,
        description: dto.description || null,
        password: dto.password,
        expiresAt: dto.expiresAt || null,
        allowUpload: dto.allowUpload ?? true,
        allowDownload: dto.showMetadata === false ? false : (dto.allowDownload ?? true),
        showExif: dto.showMetadata ?? true,
        slug: dto.slug || null,
        accessToken: dto.generateAccessToken ? this.generateAccessToken(dto.password) : null,
      });

      return mapSharedLink(sharedLink, { stripAssetMetadata: false, includeAccessToken: true });
    } catch (error) {
      this.handleError(error);
    }
  }

  /** An access token only makes sense as a bypass for a password, so it requires one. */
  private generateAccessToken(password: string | null | undefined): string {
    if (!password) {
      throw new BadRequestException('An access token requires the shared link to have a password');
    }

    return this.cryptoRepository.randomBytes(ACCESS_TOKEN_BYTES).toString('base64url');
  }

  private handleError(error: unknown): never {
    if ((error as PostgresError).constraint_name === 'shared_link_slug_uq') {
      this.logger.debug('Shared link with this slug already exists');
      throw new BadRequestException('Failed to save shared link');
    }
    throw error;
  }

  async update(auth: AuthDto, id: string, dto: SharedLinkEditDto) {
    const existing = await this.findOrFail(auth.user.id, id);
    try {
      const sharedLink = await this.sharedLinkRepository.update({
        id,
        userId: auth.user.id,
        description: dto.description,
        password: dto.password,
        expiresAt: dto.expiresAt,
        allowUpload: dto.allowUpload,
        allowDownload: dto.allowDownload,
        showExif: dto.showMetadata,
        slug: dto.slug || null,
        accessToken: this.resolveAccessToken(existing, dto),
      });
      return mapSharedLink(sharedLink, { stripAssetMetadata: false, includeAccessToken: true });
    } catch (error) {
      this.handleError(error);
    }
  }

  /** Returns the new token value, or undefined to leave it untouched. */
  private resolveAccessToken(existing: SharedLink, dto: SharedLinkEditDto): string | null | undefined {
    const password = dto.password === undefined ? existing.password : dto.password;

    if (dto.generateAccessToken === false) {
      return null;
    }

    if (dto.generateAccessToken === true) {
      // idempotent, so repeatedly saving a link does not invalidate a printed QR code
      return existing.accessToken ?? this.generateAccessToken(password);
    }

    // dropping the password makes the link public, which leaves nothing for a token to bypass
    return password || !existing.accessToken ? undefined : null;
  }

  async remove(auth: AuthDto, id: string): Promise<void> {
    const sharedLink = await this.findOrFail(auth.user.id, id);
    await this.sharedLinkRepository.remove(sharedLink.id);
  }

  // TODO: replace `userId` with permissions and access control checks
  private async findOrFail(userId: string, id: string) {
    const sharedLink = await this.sharedLinkRepository.get(userId, id);
    if (!sharedLink) {
      throw new BadRequestException('Shared link not found');
    }
    return sharedLink;
  }

  async addAssets(auth: AuthDto, id: string, dto: AssetIdsDto): Promise<AssetIdsResponseDto[]> {
    const sharedLink = await this.findOrFail(auth.user.id, id);
    if (sharedLink.type !== SharedLinkType.Individual) {
      throw new BadRequestException('Invalid shared link type');
    }

    const existingAssetIds = new Set(sharedLink.assets.map((asset) => asset.id));
    const notPresentAssetIds = dto.assetIds.filter((assetId) => !existingAssetIds.has(assetId));
    const allowedAssetIds = await this.checkAccess({
      auth,
      permission: Permission.AssetShare,
      ids: notPresentAssetIds,
    });

    const results: AssetIdsResponseDto[] = [];
    for (const assetId of dto.assetIds) {
      const hasAsset = existingAssetIds.has(assetId);
      if (hasAsset) {
        results.push({ assetId, success: false, error: AssetIdErrorReason.DUPLICATE });
        continue;
      }

      const hasAccess = allowedAssetIds.has(assetId);
      if (!hasAccess) {
        results.push({ assetId, success: false, error: AssetIdErrorReason.NO_PERMISSION });
        continue;
      }

      results.push({ assetId, success: true });
    }

    await this.sharedLinkRepository.update({
      ...sharedLink,
      assetIds: results.filter(({ success }) => success).map(({ assetId }) => assetId),
    });

    return results;
  }

  async removeAssets(auth: AuthDto, id: string, dto: AssetIdsDto): Promise<AssetIdsResponseDto[]> {
    const sharedLink = await this.findOrFail(auth.user.id, id);

    if (sharedLink.type !== SharedLinkType.Individual) {
      throw new BadRequestException('Invalid shared link type');
    }

    const removedAssetIds = await this.sharedLinkAssetRepository.remove(id, dto.assetIds);

    const results: AssetIdsResponseDto[] = [];
    for (const assetId of dto.assetIds) {
      const wasRemoved = removedAssetIds.includes(assetId);
      if (!wasRemoved) {
        results.push({ assetId, success: false, error: AssetIdErrorReason.NOT_FOUND });
        continue;
      }

      results.push({ assetId, success: true });
      sharedLink.assets = sharedLink.assets.filter((asset) => asset.id !== assetId);
    }

    await this.sharedLinkRepository.update(sharedLink);

    return results;
  }

  async getMetadataTags(auth: AuthDto, defaultDomain?: string): Promise<null | OpenGraphTags> {
    if (!auth.sharedLink || auth.sharedLink.password) {
      return null;
    }

    const config = await this.getConfig({ withCache: true });
    const sharedLink = await this.findOrFail(auth.sharedLink.userId, auth.sharedLink.id);
    const assetId = sharedLink.album?.albumThumbnailAssetId || sharedLink.assets[0]?.id;
    const assetCount = sharedLink.assets.length > 0 ? sharedLink.assets.length : sharedLink.album?.assets?.length || 0;
    const imagePath = assetId
      ? `/api/assets/${assetId}/thumbnail?key=${sharedLink.key.toString('base64url')}`
      : '/feature-panel.png';

    return {
      title: sharedLink.album ? sharedLink.album.albumName : 'Public Share',
      description: sharedLink.description || `${assetCount} shared photos & videos`,
      imageUrl: new URL(imagePath, getExternalDomain(config.server, defaultDomain)).href,
    };
  }

  private asToken(sharedLink: { id: string; password: string }) {
    return this.cryptoRepository.hashSha256(`${sharedLink.id}-${sharedLink.password}`).toString('base64');
  }
}
