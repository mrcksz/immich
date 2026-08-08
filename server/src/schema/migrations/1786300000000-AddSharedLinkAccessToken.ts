import { Kysely, sql } from 'kysely';

export async function up(db: Kysely<any>): Promise<void> {
  await sql`ALTER TABLE "shared_link" ADD "accessToken" character varying;`.execute(db);
  await sql`CREATE INDEX "shared_link_accessToken_idx" ON "shared_link" ("accessToken");`.execute(db);
}

export async function down(db: Kysely<any>): Promise<void> {
  await sql`DROP INDEX "shared_link_accessToken_idx";`.execute(db);
  await sql`ALTER TABLE "shared_link" DROP COLUMN "accessToken";`.execute(db);
}
