import sql from "mssql";
import { loadConfig, requireConnectionConfig, type SqlServerConfig } from "./config.js";

export type SqlValue = string | number | boolean | null;
export type SqlParameters = Record<string, SqlValue>;

export interface QueryLog {
  statement(statement: string): void;
  rowCount(count: number): void;
}

let cachedConfig: SqlServerConfig | undefined;
let poolPromise: Promise<sql.ConnectionPool> | undefined;

export function getConfig(): SqlServerConfig {
  cachedConfig ??= loadConfig();
  return cachedConfig;
}

export async function getPool(): Promise<sql.ConnectionPool> {
  const config = getConfig();
  requireConnectionConfig(config);
  if (!poolPromise) {
    const pool = new sql.ConnectionPool({
      server: config.server,
      port: config.port,
      database: config.database,
      user: config.username,
      password: config.password,
      options: {
        encrypt: config.encrypt,
        trustServerCertificate: config.trustServerCertificate,
        enableArithAbort: true,
      },
      pool: { max: 10, min: 0, idleTimeoutMillis: 30000 },
    });
    poolPromise = pool.connect().catch((error: unknown) => {
      poolPromise = undefined;
      throw error;
    });
  }
  return poolPromise;
}

export async function runSql<T extends Record<string, unknown> = Record<string, unknown>>(
  statement: string,
  parameters: SqlParameters = {},
  log?: QueryLog,
): Promise<sql.IResult<T>> {
  log?.statement(statement);
  const pool = await getPool();
  const request = pool.request();
  for (const [name, value] of Object.entries(parameters)) {
    if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(name)) {
      throw new Error(`Invalid SQL parameter name: ${name}`);
    }
    request.input(name, value);
  }
  const result = await request.query<T>(statement);
  const affected = result.rowsAffected.reduce((total, current) => total + current, 0);
  log?.rowCount(result.recordset && result.recordset.length > 0
    ? result.recordset.length
    : affected);
  return result;
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
