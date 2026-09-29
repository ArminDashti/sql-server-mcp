import type { SqlValue } from "./sql.js";

export interface BuiltWhere {
  clause: string;
  parameters: Record<string, SqlValue>;
}

type Operator = "eq" | "ne" | "gt" | "gte" | "lt" | "lte" | "like" | "notLike" | "in" | "notIn" | "isNull" | "isNotNull";
interface WhereCondition {
  operator: Operator;
  value?: SqlValue | SqlValue[];
}

export function splitIdentifierPath(value: string): string[] {
  const parts: string[] = [];
  let part = "";
  let inBrackets = false;
  let closedBracket = false;

  for (let index = 0; index < value.length; index += 1) {
    const character = value[index]!;
    if (inBrackets) {
      if (character === "]" && value[index + 1] === "]") {
        part += "]";
        index += 1;
      } else if (character === "]") {
        inBrackets = false;
        closedBracket = true;
      } else {
        part += character;
      }
      continue;
    }
    if (closedBracket && character !== ".") {
      throw new Error(`Invalid SQL identifier: ${value}`);
    }
    if (character === ".") {
      if (!part.trim()) throw new Error(`Invalid SQL identifier: ${value}`);
      parts.push(part.trim());
      part = "";
      closedBracket = false;
    } else if (character === "[") {
      if (part.trim()) throw new Error(`Invalid SQL identifier: ${value}`);
      inBrackets = true;
    } else if (character === "]") {
      throw new Error(`Invalid SQL identifier: ${value}`);
    } else {
      part += character;
    }
  }
  if (inBrackets || !part.trim()) throw new Error(`Invalid SQL identifier: ${value}`);
  parts.push(part.trim());
  return parts;
}

function quotePart(part: string): string {
  if (!part || part.includes("\0")) throw new Error("SQL identifiers cannot be empty");
  return "[" + part.replace(/]/g, "]]" ) + "]";
}

export function quoteIdentifier(value: string): string {
  const parts = splitIdentifierPath(value);
  if (parts.length > 2) throw new Error("Use at most schema.object identifiers");
  if (parts.includes("*") && parts.at(-1) !== "*") {
    throw new Error("Wildcard is only allowed as the final column segment");
  }
  return parts.map((part) => part === "*" ? "*" : quotePart(part)).join(".");
}

export function quoteTable(table: string, schema?: string): string {
  const parts = splitIdentifierPath(table);
  if (schema && parts.length !== 1) {
    throw new Error("Specify schema either separately or in table, not both");
  }
  if (schema) {
    const schemaParts = splitIdentifierPath(schema);
    if (schemaParts.length !== 1) throw new Error("Schema must be a single identifier");
    return `${quotePart(schemaParts[0]!)}.${quotePart(parts[0]!)}`;
  }
  if (parts.length > 2) throw new Error("Use table or schema.table");
  return parts.map(quotePart).join(".");
}

export function resolveObjectName(objectName: string, schema?: string): { name: string; schema?: string } {
  const parts = splitIdentifierPath(objectName);
  if (schema && parts.length !== 1) throw new Error("Specify schema either separately or in objectName, not both");
  if (schema) {
    const schemaParts = splitIdentifierPath(schema);
    if (schemaParts.length !== 1) throw new Error("Schema must be a single identifier");
    return { name: parts[0]!, schema: schemaParts[0]! };
  }
  if (parts.length === 2) return { schema: parts[0]!, name: parts[1]! };
  if (parts.length !== 1) throw new Error("Use objectName or schema.objectName");
  return { name: parts[0]! };
}

function isCondition(value: unknown): value is WhereCondition {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    && "operator" in value;
}

export function buildWhere(where?: Record<string, unknown>, prefix = "where"): BuiltWhere {
  const predicates: string[] = [];
  const parameters: Record<string, SqlValue> = {};
  let index = 0;

  for (const [columnName, rawValue] of Object.entries(where ?? {})) {
    const column = quoteIdentifier(columnName);
    const condition: WhereCondition = isCondition(rawValue)
      ? rawValue
      : { operator: "eq", value: rawValue as SqlValue };
    const operator = condition.operator;
    const value = condition.value;

    if (operator === "isNull" || operator === "isNotNull") {
      predicates.push(`${column} IS ${operator === "isNull" ? "" : "NOT "}NULL`);
      continue;
    }
    if (operator === "in" || operator === "notIn") {
      if (!Array.isArray(value) || value.length === 0) {
        throw new Error(`${operator} requires a non-empty value array`);
      }
      const names = value.map((item) => {
        if (item === null) throw new Error(`${operator} values cannot contain null`);
        const name = `${prefix}${index++}`;
        parameters[name] = item;
        return `@${name}`;
      });
      predicates.push(`${column} ${operator === "in" ? "IN" : "NOT IN"} (${names.join(", ")})`);
      continue;
    }
    if (value === undefined) throw new Error(`${operator} requires a value`);
    if (value === null) {
      if (operator === "eq") predicates.push(`${column} IS NULL`);
      else if (operator === "ne") predicates.push(`${column} IS NOT NULL`);
      else throw new Error(`${operator} does not accept null`);
      continue;
    }
    if (Array.isArray(value)) throw new Error(`${operator} accepts one value`);

    const name = `${prefix}${index++}`;
    parameters[name] = value;
    const sqlOperator: Record<string, string> = {
      eq: "=", ne: "<>", gt: ">", gte: ">=", lt: "<", lte: "<=", like: "LIKE", notLike: "NOT LIKE",
    };
    const translated = sqlOperator[operator];
    if (!translated) throw new Error(`Unsupported WHERE operator: ${operator}`);
    predicates.push(`${column} ${translated} @${name}`);
  }
  return { clause: predicates.length ? ` WHERE ${predicates.join(" AND ")}` : "", parameters };
}

export function buildAssignments(values: Record<string, SqlValue>): {
  clause: string;
  parameters: Record<string, SqlValue>;
} {
  const entries = Object.entries(values);
  if (!entries.length) throw new Error("At least one SET value is required");
  const parameters: Record<string, SqlValue> = {};
  const assignments = entries.map(([column, value], index) => {
    const name = `set${index}`;
    parameters[name] = value;
    return `${quoteIdentifier(column)} = @${name}`;
  });
  return { clause: assignments.join(", "), parameters };
}

export function mergeParameters(...sets: Record<string, SqlValue>[]): Record<string, SqlValue> {
  return Object.assign({}, ...sets);
}
