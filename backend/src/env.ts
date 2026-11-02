export interface Env {
  DB: D1Database;
  DERIVED: R2Bucket;
  ORIGINALS_R2: R2Bucket;
  APP_TOKEN: string;
  ORIGINALS_MODE: 's3' | 'r2';
  ORIG_ENDPOINT: string;
  ORIG_BUCKET: string;
  ORIG_REGION: string;
  ORIG_FLAVOR?: string;            // 'aws' (default) or 'goog'
  ORIG_ACCESS_KEY_ID?: string;
  ORIG_SECRET_ACCESS_KEY?: string;
  TRASH_DAYS?: string;
  CAP_NEW_ASSETS_MONTH?: string;
  CAP_DOWNLOAD_GB_MONTH?: string;
  CAP_STORED_GB?: string;
}
