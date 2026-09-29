import assert from "node:assert/strict";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { buildWhere, quoteIdentifier, quoteTable } from "./identifiers.js";
import { EXPECTED_TOOL_NAMES, registerTools } from "./tools.js";

const actualNames: string[] = [];
const registrationProbe = {
  registerTool(name: string) {
    actualNames.push(name);
  },
};

registerTools(registrationProbe as unknown as McpServer);
assert.deepEqual(actualNames, [...EXPECTED_TOOL_NAMES]);
assert.equal(quoteIdentifier("[column]]name]"), "[column]]name]");
assert.equal(quoteTable("dbo.[Order Details]"), "[dbo].[Order Details]");
assert.deepEqual(buildWhere({ Id: 12, Name: { operator: "like", value: "A%" } }), {
  clause: " WHERE [Id] = @where0 AND [Name] LIKE @where1",
  parameters: { where0: 12, where1: "A%" },
});
console.log(`Tool registration smoke passed (${actualNames.length} tools).`);
