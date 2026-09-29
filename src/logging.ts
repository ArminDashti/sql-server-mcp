import { appendFile, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { errorMessage, getConfig, type QueryLog } from "./sql.js";

export interface ToolLogger extends QueryLog {}

function logFileName(date: Date): string {
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}.log`;
}

export async function withToolLogging<T>(
  toolName: string,
  input: unknown,
  action: (log: ToolLogger) => Promise<T>,
): Promise<T> {
  const config = getConfig();
  await mkdir(config.logsDir, { recursive: true });
  const started = new Date();
  const file = join(config.logsDir, logFileName(started));
  const serialized = JSON.stringify(input, (_key, value: unknown) =>
    typeof value === "bigint" ? value.toString() : value, 2);
  await appendFile(file, [
    `timestamp: ${started.toISOString()}`,
    `tool: ${toolName}`,
    "",
    "input:",
    serialized ?? "null",
    "",
  ].join("\n"), "utf8");

  const statements: string[] = [];
  let rowCount = 0;
  const logger: ToolLogger = {
    statement: (statement) => statements.push(statement),
    rowCount: (count) => { rowCount = count; },
  };
  try {
    const result = await action(logger);
    const suffix = [
      statements.length ? `sql:\n${statements.join("\n\n")}` : "",
      `row_count: ${rowCount}`,
      "",
      "",
    ].filter(Boolean).join("\n");
    await appendFile(file, suffix, "utf8");
    return result;
  } catch (error) {
    await appendFile(file, `error: ${errorMessage(error)}\n\n`, "utf8").catch(() => undefined);
    throw error;
  }
}
