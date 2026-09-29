import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import {
  buildAssignments,
  buildWhere,
  mergeParameters,
  quoteIdentifier,
  quoteTable,
  resolveObjectName,
} from "./identifiers.js";
import { withToolLogging } from "./logging.js";
import { errorMessage, runSql, type SqlValue } from "./sql.js";

export const EXPECTED_TOOL_NAMES = [
  "list_objects",
  "test_connection",
  "insert",
  "update",
  "delete",
  "select",
  "info",
  "object_info",
  "deep_search",
] as const;

const scalarSchema = z.union([z.string(), z.number().finite(), z.boolean(), z.null()]);
const whereConditionSchema = z.object({
  operator: z.enum([
    "eq", "ne", "gt", "gte", "lt", "lte", "like", "notLike",
    "in", "notIn", "isNull", "isNotNull",
  ]),
  value: z.union([scalarSchema, z.array(scalarSchema)]).optional(),
});
const whereSchema = z.record(z.string(), z.union([scalarSchema, whereConditionSchema]));
const valueRecordSchema = z.record(z.string().min(1), scalarSchema)
  .refine((value) => Object.keys(value).length > 0, "Provide at least one column value");
const orderBySchema = z.array(z.object({
  column: z.string().min(1),
  direction: z.enum(["ASC", "DESC", "asc", "desc"]).optional(),
}));
const topSchema = z.number().int().min(1).max(100000);

type Log = Parameters<Parameters<typeof withToolLogging>[2]>[0];

function jsonText(value: unknown): { content: [{ type: "text"; text: string }] } {
  const text = JSON.stringify(value, (_key, entry: unknown) =>
    typeof entry === "bigint" ? entry.toString() : entry, 2);
  return { content: [{ type: "text", text: text ?? "null" }] };
}

async function invoke<T>(
  name: string,
  input: unknown,
  action: (log: Log) => Promise<T>,
) {
  try {
    return jsonText(await withToolLogging(name, input, action));
  } catch (error) {
    return { ...jsonText({ error: errorMessage(error) }), isError: true as const };
  }
}

function escapeLike(value: string): string {
  return [...value].map((character) => ({
    "[": "[[]",
    "%": "[%]",
    "_": "[_]",
  }[character] ?? character)).join("");
}

function mutationWhere(where: Record<string, unknown> | undefined, force: boolean): ReturnType<typeof buildWhere> {
  if (!Object.keys(where ?? {}).length && !force) {
    throw new Error("A non-empty WHERE filter is required unless force is true");
  }
  return buildWhere(where);
}

function distinctColumns(columns: string[]): void {
  const normalized = columns.map((column) => column.trim().toLowerCase());
  if (new Set(normalized).size !== normalized.length) {
    throw new Error("Column names must be unique");
  }
}

export function registerTools(server: McpServer): void {
  server.registerTool("list_objects", {
    description: "Search SQL Server tables, views, procedures, functions, and other objects.",
    inputSchema: {
      name: z.string().optional(),
      schema: z.string().optional(),
      type: z.string().optional(),
      search: z.string().optional(),
      limit: z.number().int().min(1).max(1000).default(100),
    },
  }, async (args) => invoke("list_objects", args, async (log) => {
    const predicates = ["o.is_ms_shipped = 0"];
    const parameters: Record<string, SqlValue> = { limit: args.limit };
    if (args.name) {
      predicates.push("o.name LIKE @namePattern");
      parameters.namePattern = "%" + escapeLike(args.name) + "%";
    }
    if (args.schema) {
      predicates.push("s.name = @schemaName");
      parameters.schemaName = args.schema;
    }
    if (args.type) {
      predicates.push(`(
        o.type = @objectType OR o.type_desc = @objectType
        OR (LOWER(@objectType) = N'table' AND o.type = 'U')
        OR (LOWER(@objectType) IN (N'procedure', N'stored procedure') AND o.type = 'P')
        OR (LOWER(@objectType) = N'view' AND o.type = 'V')
        OR (LOWER(@objectType) = N'function' AND o.type IN ('FN', 'IF', 'TF', 'FS', 'FT'))
      )`);
      parameters.objectType = args.type;
    }
    if (args.search) {
      predicates.push("(o.name LIKE @searchPattern OR s.name LIKE @searchPattern OR o.type_desc LIKE @searchPattern)");
      parameters.searchPattern = "%" + escapeLike(args.search) + "%";
    }
    const result = await runSql(`
      SELECT TOP (@limit)
        s.name AS schemaName,
        o.name AS name,
        o.type AS type,
        o.type_desc AS typeDescription,
        o.create_date AS createdAt,
        o.modify_date AS modifiedAt
      FROM sys.objects AS o
      INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
      WHERE ${predicates.join(" AND ")}
      ORDER BY s.name, o.name
    `, parameters, log);
    return { count: result.recordset.length, objects: result.recordset };
  }));

  server.registerTool("test_connection", {
    description: "Test SQL Server connectivity and return server/database identity.",
    inputSchema: {},
  }, async (args) => invoke("test_connection", args, async (log) => {
    try {
      const result = await runSql(`
        SELECT
          CONVERT(nvarchar(256), SERVERPROPERTY('ServerName')) AS serverName,
          CONVERT(nvarchar(256), SERVERPROPERTY('ProductVersion')) AS version,
          DB_NAME() AS databaseName
      `, {}, log);
      return { success: true, ...result.recordset[0] };
    } catch (error) {
      return { success: false, error: errorMessage(error) };
    }
  }));

  const insertSchema = z.object({
    table: z.string().min(1),
    schema: z.string().optional(),
    row: valueRecordSchema.optional(),
    columns: z.array(z.string().min(1)).min(1).optional(),
    values: z.array(scalarSchema).optional(),
  }).superRefine((value, context) => {
    const hasRow = value.row !== undefined;
    const hasColumns = value.columns !== undefined || value.values !== undefined;
    if (hasRow === hasColumns) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: "Provide row or both columns and values" });
      return;
    }
    if (hasColumns && (!value.columns || !value.values || value.columns.length !== value.values.length)) {
      context.addIssue({ code: z.ZodIssueCode.custom, message: "columns and values must both be provided with matching lengths" });
    }
  });
  server.registerTool("insert", {
    description: "Insert one row using parameterized values.",
    inputSchema: {
      table: z.string().min(1),
      schema: z.string().optional(),
      row: valueRecordSchema.optional(),
      columns: z.array(z.string().min(1)).min(1).optional(),
      values: z.array(scalarSchema).optional(),
    },
  }, async (args) => invoke("insert", args, async (log) => {
    const input = insertSchema.parse(args);
    const entries: [string, SqlValue][] = input.row
      ? Object.entries(input.row)
      : input.columns!.map((column, index) => [column, input.values![index]!]);
    distinctColumns(entries.map(([column]) => column));
    const table = quoteTable(input.table, input.schema);
    const parameters: Record<string, SqlValue> = {};
    const columnSql = entries.map(([column]) => quoteIdentifier(column));
    const valueSql = entries.map(([, value], index) => {
      const name = `value${index}`;
      parameters[name] = value;
      return `@${name}`;
    });
    const result = await runSql(
      `INSERT INTO ${table} (${columnSql.join(", ")}) VALUES (${valueSql.join(", ")})`,
      parameters,
      log,
    );
    return { rowsAffected: result.rowsAffected.reduce((sum, count) => sum + count, 0) };
  }));

  const updateSchema = z.object({
    table: z.string().min(1),
    schema: z.string().optional(),
    set: valueRecordSchema,
    where: whereSchema.optional(),
    force: z.boolean().optional().default(false),
    top: topSchema.optional(),
  }).superRefine((value, context) => {
    if (!Object.keys(value.where ?? {}).length && !value.force) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ["where"], message: "WHERE is required unless force is true" });
    }
  });
  server.registerTool("update", {
    description: "Update rows with parameterized SET and WHERE values; force is required for an unfiltered update.",
    inputSchema: {
      table: z.string().min(1),
      schema: z.string().optional(),
      set: valueRecordSchema,
      where: whereSchema.optional(),
      force: z.boolean().optional().default(false),
      top: topSchema.optional(),
    },
  }, async (args) => invoke("update", args, async (log) => {
    const input = updateSchema.parse(args);
    const table = quoteTable(input.table, input.schema);
    const assignments = buildAssignments(input.set);
    const where = mutationWhere(input.where, input.force);
    const top = input.top ? ` TOP (${input.top})` : "";
    const result = await runSql(
      `UPDATE${top} ${table} SET ${assignments.clause}${where.clause}`,
      mergeParameters(assignments.parameters, where.parameters),
      log,
    );
    return { rowsAffected: result.rowsAffected.reduce((sum, count) => sum + count, 0) };
  }));

  const deleteSchema = z.object({
    table: z.string().min(1),
    schema: z.string().optional(),
    where: whereSchema.optional(),
    force: z.boolean().optional().default(false),
    top: topSchema.optional(),
  }).superRefine((value, context) => {
    if (!Object.keys(value.where ?? {}).length && !value.force) {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ["where"], message: "WHERE is required unless force is true" });
    }
  });
  server.registerTool("delete", {
    description: "Delete rows with parameterized WHERE values; force is required for an unfiltered delete.",
    inputSchema: {
      table: z.string().min(1),
      schema: z.string().optional(),
      where: whereSchema.optional(),
      force: z.boolean().optional().default(false),
      top: topSchema.optional(),
    },
  }, async (args) => invoke("delete", args, async (log) => {
    const input = deleteSchema.parse(args);
    const table = quoteTable(input.table, input.schema);
    const where = mutationWhere(input.where, input.force);
    const top = input.top ? ` TOP (${input.top})` : "";
    const result = await runSql(
      `DELETE${top} FROM ${table}${where.clause}`,
      where.parameters,
      log,
    );
    return { rowsAffected: result.rowsAffected.reduce((sum, count) => sum + count, 0) };
  }));

  server.registerTool("select", {
    description: "Select rows with optional filters, grouping, ordering, and TOP; all filter values are parameterized.",
    inputSchema: {
      table: z.string().min(1),
      schema: z.string().optional(),
      columns: z.array(z.string().min(1)).min(1).optional(),
      where: whereSchema.optional(),
      orderBy: orderBySchema.optional(),
      groupBy: z.array(z.string().min(1)).optional(),
      top: topSchema.optional(),
    },
  }, async (args) => invoke("select", args, async (log) => {
    const table = quoteTable(args.table, args.schema);
    const selectedColumns = args.columns?.map(quoteIdentifier).join(", ") || "*";
    const where = buildWhere(args.where);
    const groupBy = args.groupBy?.length
      ? ` GROUP BY ${args.groupBy.map(quoteIdentifier).join(", ")}`
      : "";
    const orderBy = args.orderBy?.length
      ? ` ORDER BY ${args.orderBy.map(({ column, direction }) =>
        `${quoteIdentifier(column)} ${direction?.toUpperCase() === "DESC" ? "DESC" : "ASC"}`).join(", ")}`
      : "";
    const top = args.top ? ` TOP (${args.top})` : "";
    const result = await runSql(
      `SELECT${top} ${selectedColumns} FROM ${table}${where.clause}${groupBy}${orderBy}`,
      where.parameters,
      log,
    );
    return { count: result.recordset.length, rows: result.recordset };
  }));

  server.registerTool("info", {
    description: "Return SQL Server version, edition, database settings, collation, and database file sizes.",
    inputSchema: {},
  }, async (args) => invoke("info", args, async (log) => {
    const instance = await runSql(`
      SELECT
        CONVERT(nvarchar(256), SERVERPROPERTY('ServerName')) AS serverName,
        CONVERT(nvarchar(256), SERVERPROPERTY('MachineName')) AS machineName,
        CONVERT(nvarchar(256), SERVERPROPERTY('ProductVersion')) AS productVersion,
        CONVERT(nvarchar(256), SERVERPROPERTY('ProductLevel')) AS productLevel,
        CONVERT(nvarchar(256), SERVERPROPERTY('Edition')) AS edition,
        CONVERT(int, SERVERPROPERTY('EngineEdition')) AS engineEdition,
        CONVERT(nvarchar(256), SERVERPROPERTY('InstanceName')) AS instanceName
    `, {}, log);
    const database = await runSql(`
      SELECT
        d.name AS databaseName,
        d.compatibility_level AS compatibilityLevel,
        d.collation_name AS collation,
        d.state_desc AS state,
        CAST(COALESCE(SUM(CONVERT(bigint, f.size)), 0) * 8.0 / 1024 AS decimal(18, 2)) AS totalSizeMB,
        CAST(COALESCE(SUM(CASE WHEN f.type = 0 THEN CONVERT(bigint, f.size) ELSE 0 END), 0) * 8.0 / 1024 AS decimal(18, 2)) AS dataSizeMB,
        CAST(COALESCE(SUM(CASE WHEN f.type = 1 THEN CONVERT(bigint, f.size) ELSE 0 END), 0) * 8.0 / 1024 AS decimal(18, 2)) AS logSizeMB
      FROM sys.databases AS d
      LEFT JOIN sys.database_files AS f ON 1 = 1
      WHERE d.database_id = DB_ID()
      GROUP BY d.name, d.compatibility_level, d.collation_name, d.state_desc
    `, {}, log);
    return { instance: instance.recordset[0], database: database.recordset[0] };
  }));

  server.registerTool("object_info", {
    description: "Return columns, indexes, routine parameters/definition, and foreign keys for one object.",
    inputSchema: {
      objectName: z.string().min(1),
      schema: z.string().optional(),
    },
  }, async (args) => invoke("object_info", args, async (log) => {
    const requested = resolveObjectName(args.objectName, args.schema);
    const objectParameters: Record<string, SqlValue> = { objectName: requested.name };
    const schemaPredicate = requested.schema === undefined ? "" : " AND s.name = @schemaName";
    if (requested.schema !== undefined) objectParameters.schemaName = requested.schema;
    const objectResult = await runSql(`
      SELECT TOP (2)
        o.object_id AS objectId,
        s.name AS schemaName,
        o.name AS objectName,
        o.type AS objectType,
        o.type_desc AS typeDescription,
        o.create_date AS createdAt,
        o.modify_date AS modifiedAt,
        m.definition AS definition
      FROM sys.objects AS o
      INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
      LEFT JOIN sys.sql_modules AS m ON m.object_id = o.object_id
      WHERE o.name = @objectName${schemaPredicate}
      ORDER BY s.name, o.name
    `, objectParameters, log);
    const matches = objectResult.recordset;
    if (matches.length === 0) return { found: false, objectName: args.objectName };
    if (matches.length > 1) {
      return {
        found: false,
        ambiguous: true,
        candidates: matches.map(({ schemaName, objectName, typeDescription }) => ({ schemaName, objectName, typeDescription })),
      };
    }
    const object = matches[0]!;
    const objectId = object.objectId as number;
    const [columnResult, indexResult, parameterResult, foreignKeyResult] = await Promise.all([
      runSql(`
        SELECT
          c.column_id AS ordinal,
          c.name AS name,
          typeSchema.name AS typeSchema,
          t.name AS dataType,
          c.max_length AS maxLengthBytes,
          c.precision AS precision,
          c.scale AS scale,
          c.is_nullable AS isNullable,
          c.is_identity AS isIdentity,
          c.is_computed AS isComputed,
          dc.definition AS defaultDefinition,
          cc.definition AS computedDefinition
        FROM sys.columns AS c
        INNER JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        INNER JOIN sys.schemas AS typeSchema ON typeSchema.schema_id = t.schema_id
        LEFT JOIN sys.default_constraints AS dc ON dc.object_id = c.default_object_id
        LEFT JOIN sys.computed_columns AS cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
        WHERE c.object_id = @objectId
        ORDER BY c.column_id
      `, { objectId }, log),
      runSql(`
        SELECT
          i.index_id AS indexId,
          i.name AS name,
          i.type_desc AS type,
          i.is_unique AS isUnique,
          i.is_primary_key AS isPrimaryKey,
          i.is_unique_constraint AS isUniqueConstraint,
          c.name AS columnName,
          ic.key_ordinal AS keyOrdinal,
          ic.is_included_column AS isIncluded
        FROM sys.indexes AS i
        LEFT JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
        LEFT JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE i.object_id = @objectId AND i.index_id > 0
        ORDER BY i.index_id, ic.key_ordinal, ic.index_column_id
      `, { objectId }, log),
      runSql(`
        SELECT
          p.parameter_id AS ordinal,
          p.name AS name,
          typeSchema.name AS typeSchema,
          t.name AS dataType,
          p.max_length AS maxLengthBytes,
          p.precision AS precision,
          p.scale AS scale,
          p.is_output AS isOutput,
          p.has_default_value AS hasDefaultValue,
          p.default_value AS defaultValue
        FROM sys.parameters AS p
        INNER JOIN sys.types AS t ON t.user_type_id = p.user_type_id
        INNER JOIN sys.schemas AS typeSchema ON typeSchema.schema_id = t.schema_id
        WHERE p.object_id = @objectId
        ORDER BY p.parameter_id
      `, { objectId }, log),
      runSql(`
        SELECT
          fk.name AS name,
          CASE WHEN fk.parent_object_id = @objectId THEN N'outgoing' ELSE N'incoming' END AS direction,
          parentSchema.name AS parentSchema,
          parentTable.name AS parentTable,
          parentColumn.name AS parentColumn,
          referencedSchema.name AS referencedSchema,
          referencedTable.name AS referencedTable,
          referencedColumn.name AS referencedColumn,
          fk.delete_referential_action_desc AS onDelete,
          fk.update_referential_action_desc AS onUpdate,
          fk.is_disabled AS isDisabled,
          fkc.constraint_column_id AS ordinal
        FROM sys.foreign_keys AS fk
        INNER JOIN sys.foreign_key_columns AS fkc ON fkc.constraint_object_id = fk.object_id
        INNER JOIN sys.tables AS parentTable ON parentTable.object_id = fk.parent_object_id
        INNER JOIN sys.schemas AS parentSchema ON parentSchema.schema_id = parentTable.schema_id
        INNER JOIN sys.columns AS parentColumn ON parentColumn.object_id = fkc.parent_object_id AND parentColumn.column_id = fkc.parent_column_id
        INNER JOIN sys.tables AS referencedTable ON referencedTable.object_id = fk.referenced_object_id
        INNER JOIN sys.schemas AS referencedSchema ON referencedSchema.schema_id = referencedTable.schema_id
        INNER JOIN sys.columns AS referencedColumn ON referencedColumn.object_id = fkc.referenced_object_id AND referencedColumn.column_id = fkc.referenced_column_id
        WHERE fk.parent_object_id = @objectId OR fk.referenced_object_id = @objectId
        ORDER BY fk.name, fkc.constraint_column_id
      `, { objectId }, log),
    ]);

    const indexesById = new Map<number, Record<string, unknown> & { columns: unknown[] }>();
    for (const row of indexResult.recordset) {
      const id = row.indexId as number;
      let index = indexesById.get(id);
      if (!index) {
        index = {
          indexId: id,
          name: row.name,
          type: row.type,
          isUnique: row.isUnique,
          isPrimaryKey: row.isPrimaryKey,
          isUniqueConstraint: row.isUniqueConstraint,
          columns: [],
        };
        indexesById.set(id, index);
      }
      if (row.columnName) index.columns.push({ name: row.columnName, keyOrdinal: row.keyOrdinal, included: row.isIncluded });
    }

    const foreignKeysByName = new Map<string, Record<string, unknown> & { columns: unknown[] }>();
    for (const row of foreignKeyResult.recordset) {
      const key = `${String(row.direction)}:${String(row.name)}`;
      let foreignKey = foreignKeysByName.get(key);
      if (!foreignKey) {
        foreignKey = {
          name: row.name,
          direction: row.direction,
          parentSchema: row.parentSchema,
          parentTable: row.parentTable,
          referencedSchema: row.referencedSchema,
          referencedTable: row.referencedTable,
          onDelete: row.onDelete,
          onUpdate: row.onUpdate,
          isDisabled: row.isDisabled,
          columns: [],
        };
        foreignKeysByName.set(key, foreignKey);
      }
      foreignKey.columns.push({ parent: row.parentColumn, referenced: row.referencedColumn });
    }

    return {
      found: true,
      object: {
        ...object,
        columns: columnResult.recordset,
        indexes: [...indexesById.values()],
        parameters: parameterResult.recordset,
        foreignKeys: [...foreignKeysByName.values()],
      },
    };
  }));

  server.registerTool("deep_search", {
    description: "Rank matches across object, schema, column, parameter, and module-definition metadata.",
    inputSchema: {
      search: z.string().min(1).max(200),
      limit: z.number().int().min(1).max(500).default(50),
    },
  }, async (args) => invoke("deep_search", args, async (log) => {
    const term = args.search.trim();
    if (!term) throw new Error("search must not be blank");
    const pattern = "%" + escapeLike(term) + "%";
    const result = await runSql(`
      WITH matches AS (
        SELECT N'object' AS matchType, s.name AS schemaName, o.name AS name,
          CONVERT(nvarchar(1000), o.type_desc) AS extra
        FROM sys.objects AS o
        INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        WHERE o.is_ms_shipped = 0
        UNION ALL
        SELECT N'schema', CONVERT(nvarchar(128), NULL), s.name,
          CONVERT(nvarchar(1000), N'SQL schema')
        FROM sys.schemas AS s
        WHERE s.name NOT IN (N'sys', N'INFORMATION_SCHEMA')
        UNION ALL
        SELECT N'column', s.name, c.name,
          CONVERT(nvarchar(1000), o.name + N' (' + o.type_desc + N')')
        FROM sys.columns AS c
        INNER JOIN sys.objects AS o ON o.object_id = c.object_id
        INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        WHERE o.is_ms_shipped = 0
        UNION ALL
        SELECT N'parameter', s.name, p.name,
          CONVERT(nvarchar(1000), o.name + N' (' + o.type_desc + N')')
        FROM sys.parameters AS p
        INNER JOIN sys.objects AS o ON o.object_id = p.object_id
        INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        WHERE o.is_ms_shipped = 0 AND p.name IS NOT NULL
        UNION ALL
        SELECT N'module_definition', s.name, o.name,
          CONVERT(nvarchar(1000), SUBSTRING(m.definition,
            CASE WHEN CHARINDEX(LOWER(@term), LOWER(m.definition)) > 80
              THEN CHARINDEX(LOWER(@term), LOWER(m.definition)) - 80 ELSE 1 END, 220))
        FROM sys.sql_modules AS m
        INNER JOIN sys.objects AS o ON o.object_id = m.object_id
        INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        WHERE o.is_ms_shipped = 0 AND m.definition IS NOT NULL
          AND LOWER(m.definition) LIKE LOWER(@pattern)
      )
      SELECT TOP (@limit)
        matchType,
        schemaName,
        name,
        extra,
        CASE
          WHEN LOWER(name) = LOWER(@term) THEN 0
          WHEN LOWER(name) LIKE LOWER(@prefix) THEN 1
          WHEN LOWER(name) LIKE LOWER(@pattern) THEN 2
          ELSE 3
        END AS rank
      FROM matches
      WHERE LOWER(COALESCE(name, N'')) LIKE LOWER(@pattern)
         OR LOWER(COALESCE(schemaName, N'')) LIKE LOWER(@pattern)
         OR LOWER(COALESCE(extra, N'')) LIKE LOWER(@pattern)
      ORDER BY rank, matchType, schemaName, name
    `, {
      term,
      prefix: escapeLike(term) + "%",
      pattern,
      limit: args.limit,
    }, log);
    return { count: result.recordset.length, matches: result.recordset };
  }));
}
