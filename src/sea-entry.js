// Single-executable (SEA) entry point: reaches the compiled server modules and
// starts the stdio transport. Bundled to CommonJS by scripts/installer-win-x64.ps1.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerTools } from "../dist/tools.js";

const server = new McpServer({ name: "sql-server-mcp", version: "0.0.0" });
registerTools(server);
void server.connect(new StdioServerTransport());
