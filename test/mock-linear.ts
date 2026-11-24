// A tiny stand-in for Linear's GraphQL API, for trying the plugin without a real key.
//
//   bun test/mock-linear.ts            # listens on 127.0.0.1:4466
//   LINEAR_API_URL=http://127.0.0.1:4466/graphql LINEAR_API_KEY=lin_api_mock tern ...
//
// The plugin only accepts a LINEAR_API_URL that points at this machine. Issues: ABC-1 (everything
// filled in), ABC-2 (nearly empty), ABC-404 (not found); any other identifier is "not found" too.
// Set MOCK_ATTACHMENT_URL to add one more attachment to ABC-1.

const KEY = "lin_api_mock";
const port = Number(process.env.MOCK_PORT ?? 4466);

const now = Date.now();

const attachments = [
  { title: "Add token bucket limiter", url: "https://github.com/acme/api/pull/42", subtitle: "acme/api#42" },
  { title: "Design notes", url: "https://example.com/design-notes", subtitle: null },
];
if (process.env.MOCK_ATTACHMENT_URL) {
  attachments.push({ title: "Extra link", url: process.env.MOCK_ATTACHMENT_URL, subtitle: null });
}

const issues: Record<string, unknown> = {
  "ABC-1": {
    identifier: "ABC-1",
    title: "Add rate limiting to the public API",
    url: "https://linear.app/acme/issue/ABC-1/add-rate-limiting-to-the-public-api",
    description: [
      "Clients can currently send unlimited requests. Add a **token bucket** per API key.",
      "",
      "## Acceptance",
      "",
      "- 429 with `Retry-After` when the bucket is empty",
      "- Limits configurable per plan",
      "- Metrics for rejected requests",
      "",
      "```ts",
      "const limiter = new TokenBucket({ capacity: 100, refillPerSecond: 10 });",
      "```",
      "",
      "![diagram](https://example.com/diagram.png)",
    ].join("\n"),
    priority: 2,
    priorityLabel: "High",
    state: { name: "In Progress", type: "started", color: "#f2c94c" },
    assignee: { name: "Sam Rivera" },
    project: { name: "Platform" },
    parent: { identifier: "ABC-9", title: "Q4 reliability", url: "https://linear.app/acme/issue/ABC-9/q4-reliability" },
    attachments: { nodes: attachments },
    comments: {
      nodes: [
        { body: "Started on this today; the limiter itself is small.", createdAt: new Date(now - 30 * 3_600_000).toISOString(), user: { name: "Sam Rivera" } },
        { body: "Remember the **admin** endpoints need a higher ceiling.", createdAt: new Date(now - 12 * 60_000).toISOString(), user: { name: "Dana Lee" } },
      ],
    },
  },
  "ABC-2": {
    identifier: "ABC-2",
    title: "Typo in the onboarding email",
    url: "https://linear.app/acme/issue/ABC-2/typo-in-the-onboarding-email",
    description: null,
    priority: 0,
    priorityLabel: "No priority",
    state: { name: "Backlog", type: "backlog", color: "#bec2c8" },
    assignee: null,
    project: null,
    parent: null,
    attachments: { nodes: [] },
    comments: { nodes: [] },
  },
};

Bun.serve({
  hostname: "127.0.0.1",
  port,
  async fetch(req) {
    if (req.method !== "POST") return new Response("mock linear", { status: 200 });
    if (req.headers.get("authorization") !== KEY) {
      return Response.json({ errors: [{ message: "Authentication required", extensions: { code: "AUTHENTICATION_ERROR" } }] }, { status: 401 });
    }
    const body = (await req.json()) as { operationName?: string; variables?: { id?: string } };
    if (body.operationName === "Viewer") {
      return Response.json({
        data: { viewer: { name: "Sam Rivera", organization: { name: "Acme", urlKey: "acme" }, teams: { nodes: [{ key: "ABC" }] } } },
      });
    }
    if (body.operationName === "Issue") {
      const issue = issues[(body.variables?.id ?? "").toUpperCase()];
      if (!issue) {
        return Response.json({ data: null, errors: [{ message: "Entity not found: Issue", extensions: { code: "ENTITY_NOT_FOUND" } }] });
      }
      return Response.json({ data: { issue } });
    }
    return Response.json({ errors: [{ message: "Unknown operation" }] }, { status: 400 });
  },
});

console.log(`mock Linear on http://127.0.0.1:${port}/graphql (key ${KEY})`);
