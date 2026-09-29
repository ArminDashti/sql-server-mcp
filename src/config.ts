import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, resolve } from "node:path";

interface FileConfig {
  server?: string;
  port?: number | string;
  database?: string;
  username?: string;
  user?: string;
  password?: string;
  trustServerCertificate?: boolean | string;
  encrypt?: boolean | string;
  logsDir?: string;
}

export interface SqlServerConfig {
  server: string;
  port: number;
  database: string;
  username: string;
  password: string;
  trustServerCertificate: boolean;
  encrypt: boolean;
  logsDir: string;
}

function expandPath(value: string): string {
  const expanded = value === "~" ? homedir() : value.startsWith("~/")
    ? resolve(homedir(), value.slice(2))
    : value;
  return isAbsolute(expanded) ? expanded : resolve(process.cwd(), expanded);
}

function parseBoolean(value: unknown, fallback: boolean, key: string): boolean {
  if (value === undefined || value === null || value === "") return fallback;
  if (typeof value === "boolean") return value;
  if (typeof value === "string") {
    if (value.toLowerCase() === "true") return true;
    if (value.toLowerCase() === "false") return false;
  }
  throw new Error(`Invalid boolean configuration for ${key}`);
}

function readFileConfig(env: NodeJS.ProcessEnv): FileConfig {
  const configPath = expandPath(env.SQL_SERVER_CONFIG || "./config.json");
  if (!existsSync(configPath)) return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(configPath, "utf8"));
  } catch (error) {
    throw new Error(`Could not read SQL Server configuration at ${configPath}: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`SQL Server configuration at ${configPath} must be a JSON object`);
  }
  return parsed as FileConfig;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): SqlServerConfig {
  const file = readFileConfig(env);
  const portValue = env.SQL_PORT ?? file.port ?? 1433;
  const port = Number(portValue);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error("SQL_PORT/config port must be an integer from 1 to 65535");
  }

  return {
    server: env.SQL_SERVER ?? file.server ?? "",
    port,
    database: env.SQL_DATABASE ?? file.database ?? "",
    username: env.SQL_USERNAME ?? file.username ?? file.user ?? "",
    password: env.SQL_PASSWORD ?? file.password ?? "",
    trustServerCertificate: parseBoolean(
      env.SQL_TRUST_SERVER_CERTIFICATE ?? file.trustServerCertificate,
      true,
      "SQL_TRUST_SERVER_CERTIFICATE",
    ),
    encrypt: parseBoolean(env.SQL_ENCRYPT ?? file.encrypt, true, "SQL_ENCRYPT"),
    logsDir: expandPath(env.SQL_LOGS_DIR ?? file.logsDir ?? "~/sql-server-mcp"),
  };
}

export function requireConnectionConfig(config: SqlServerConfig): void {
  const missing = [
    ["SQL_SERVER", config.server],
    ["SQL_DATABASE", config.database],
    ["SQL_USERNAME", config.username],
    ["SQL_PASSWORD", config.password],
  ].filter(([, value]) => !value).map(([key]) => key);
  if (missing.length) {
    throw new Error(`Missing SQL Server configuration: ${missing.join(", ")}`);
  }
}
