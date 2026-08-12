# SQL Server MCP Server

An [MCP](https://modelcontextprotocol.io) server that connects agents to Microsoft SQL Server with structured and raw query tools. Every agent query input is logged to `~/sql-server-mcp/<MMDD>-<HHmmss>.log`.

## Tools

| Tool | Description |
|------|-------------|
| `query` | Structured SELECT with `select`, `where`, `row_limit`, `group_by`, `order_by`, `count`, and optional CSV export |
| `raw_query` | Execute any SQL the agent needs, with optional named parameters |

## Prerequisites

- Node.js 18+
- Access to a SQL Server instance

## Setup

```bash
npm install
cp config.example.json config.json
# Edit config.json with your server, database, username, and password
npm run build
```

## Configuration

### `config.json`

Path via `SQL_SERVER_CONFIG` (default: `./config.json`):

```json
{
  "server": "localhost",
  "port": 1433,
  "database": "MyDatabase",
  "username": "sa",
  "password": "your-password-here",
  "trustServerCertificate": true,
  "encrypt": true,
  "logsDir": "~/sql-server-mcp",
  "csvDir": "~/sql-server-mcp/csv"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `server` | Yes | SQL Server host name or IP |
| `port` | No | SQL Server port (default: `1433`) |
| `database` | Yes | Database name |
| `username` | Yes | SQL login username |
| `password` | Yes | SQL login password |
| `trustServerCertificate` | No | Trust self-signed certs (default: `true`) |
| `encrypt` | No | Encrypt connection (default: `true`) |
| `logsDir` | No | Query log directory (default: `~/sql-server-mcp`) |
| `csvDir` | No | CSV export directory (default: `~/sql-server-mcp/csv`) |

Environment variables override `config.json`:

| Variable | Description |
|----------|-------------|
| `SQL_SERVER` | Server host |
| `SQL_PORT` | Server port |
| `SQL_DATABASE` | Database name |
| `SQL_USERNAME` | Username |
| `SQL_PASSWORD` | Password |
| `SQL_SERVER_CONFIG` | Path to config file |
| `SQL_TRUST_SERVER_CERTIFICATE` | `true` or `false` |
| `SQL_ENCRYPT` | `true` or `false` |
| `SQL_LOGS_DIR` | Log directory |
| `SQL_CSV_DIR` | CSV export directory |

## Query logs

Every tool call writes a log file under `~/sql-server-mcp/` named like `0623-151833.log` (month-day and time).

Example log:

```
timestamp: 2026-06-23T15:18:33.000Z
tool: query

input:
{
  "table": "Users",
  "select": ["Id", "Name"],
  "where": "IsActive = 1",
  "row_limit": 100
}

sql:
SELECT TOP (100) [Id], [Name] FROM [Users] WHERE IsActive = 1

row_count: 42
```

## Cursor Configuration

```json
{
  "mcpServers": {
    "sql-server": {
      "command": "node",
      "args": ["C:/Users/armin/GitHub/sql-server-mcp/dist/index.js"],
      "env": {
        "SQL_SERVER_CONFIG": "C:/Users/armin/GitHub/sql-server-mcp/config.json"
      }
    }
  }
}
```

Or pass credentials via environment variables:

```json
{
  "mcpServers": {
    "sql-server": {
      "command": "node",
      "args": ["C:/Users/armin/GitHub/sql-server-mcp/dist/index.js"],
      "env": {
        "SQL_SERVER": "localhost",
        "SQL_DATABASE": "MyDatabase",
        "SQL_USERNAME": "sa",
        "SQL_PASSWORD": "your-password"
      }
    }
  }
}
```

## Usage Examples

### Structured query

```json
{
  "table": "Orders",
  "select": ["OrderId", "CustomerId", "Total"],
  "where": "OrderDate >= '2026-01-01'",
  "row_limit": 50,
  "order_by": [{ "column": "OrderDate", "direction": "DESC" }],
  "store_on_disk_as_csv": true
}
```

### Count

```json
{
  "table": "Orders",
  "where": "Status = 'Pending'",
  "count": true
}
```

### Group by with count

```json
{
  "table": "Orders",
  "group_by": ["Status"],
  "count": true,
  "order_by": [{ "column": "Status" }]
}
```

### Raw query

```json
{
  "sql": "SELECT TOP 10 * FROM dbo.Products WHERE CategoryId = @categoryId",
  "parameters": {
    "categoryId": 5
  }
}
```

## Development

```bash
npm run dev    # Run with tsx (stdio transport)
npm run build  # Compile to dist/
npm start      # Run compiled server
```

## License

MIT
