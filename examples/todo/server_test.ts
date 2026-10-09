import { startServer } from "./server.ts";

function assert(
  condition: unknown,
  message = "Assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function equal(actual: unknown, expected: unknown) {
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`,
  );
}

type RpcReply = {
  jsonrpc: string;
  id: unknown;
  result?: { tasks: { id: number; title: string }[] };
  error?: { code: number; message: string; data?: { code: string } };
};

Deno.test("Todo MPA and JSON-RPC use a real Kom backend", async () => {
  const app = startServer(0);
  const base = `http://127.0.0.1:${app.server.addr.port}`;
  let id = 0;
  async function post(body: unknown) {
    return await fetch(base + "/rpc", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
  }
  async function rpc(method: string, params: unknown = {}) {
    const requestId = ++id;
    const response = await post({
      jsonrpc: "2.0",
      id: requestId,
      method,
      params,
    });
    equal(response.status, 200);
    const reply = await response.json() as RpcReply;
    equal(reply.jsonrpc, "2.0");
    equal(reply.id, requestId);
    return reply;
  }
  async function page(path: string) {
    const response = await fetch(base + path);
    equal(response.status, 200);
    assert(response.headers.get("Content-Type")?.includes("text/html"));
    return await response.text();
  }
  try {
    const empty = await page("/");
    assert(empty.includes("Czysta karta"));
    assert(empty.includes('href="/new"'));
    const form = await page("/new");
    assert(form.includes('data-rpc="todo.add"'));
    assert(form.includes('name="title"'));
    for (const path of ["/app.js", "/style.css"]) {
      const response = await fetch(base + path);
      equal(response.status, 200);
      assert((await response.text()).length > 0);
    }
    equal((await rpc("todo.list")).result, { tasks: [] });
    equal((await rpc("todo.add", { title: "  Kupić mleko  " })).result, {
      tasks: [{ id: 1, title: "Kupić mleko" }],
    });
    const firstTwo =
      (await rpc("todo.add", { title: "Zadzwonić do Oli" })).result;
    equal(firstTwo, {
      tasks: [
        { id: 1, title: "Kupić mleko" },
        { id: 2, title: "Zadzwonić do Oli" },
      ],
    });
    const list = await page("/");
    assert(list.includes("Kupić mleko"));
    assert(list.includes('data-rpc="todo.remove"'));
    equal(
      (await rpc("todo.add", { title: " \t\n " })).error?.data?.code,
      "InvalidTitle",
    );
    equal(
      (await rpc("todo.add", { title: "ą".repeat(251) })).error?.data?.code,
      "InvalidTitle",
    );
    equal(
      (await rpc("todo.remove", { id: -1 })).error?.data?.code,
      "InvalidId",
    );
    equal(
      (await rpc("todo.remove", { id: 999 })).error?.data?.code,
      "NotFound",
    );
    for (
      const [method, params] of [
        ["todo.add", { title: 3 }],
        ["todo.add", {}],
        ["todo.add", { title: "x", extra: true }],
        ["todo.add", ["x"]],
        ["todo.remove", { id: "1" }],
        ["todo.remove", { id: 1.5 }],
        ["todo.list", { unexpected: true }],
      ] as const
    ) {
      equal((await rpc(method, params)).error?.code, -32602);
    }
    equal((await rpc("todo.list")).result, firstTwo);
    equal((await rpc("todo.remove", { id: 1 })).result, {
      tasks: [{ id: 2, title: "Zadzwonić do Oli" }],
    });
    equal((await rpc("todo.remove", { id: 1 })).error?.data?.code, "NotFound");
    const unsafe = "<img src=x onerror=\"alert(1)\"> & 'tekst'";
    const added = await rpc("todo.add", { title: unsafe });
    equal(added.result?.tasks[1], { id: 3, title: unsafe });
    const escaped = await page("/");
    assert(!escaped.includes("<img src=x"));
    assert(
      escaped.includes(
        "&lt;img src=x onerror=&quot;alert(1)&quot;&gt; &amp; &#39;tekst&#39;",
      ),
    );
    equal((await rpc("unknown")).error?.code, -32601);
    for (
      const invalid of [
        null,
        7,
        {},
        { jsonrpc: "1.0", id: 4, method: "todo.list" },
        { jsonrpc: "2.0", id: {}, method: "todo.list" },
        [],
      ]
    ) {
      const response = await post(invalid);
      equal((await response.json()).error.code, -32600);
    }
    const malformed = await fetch(base + "/rpc", {
      method: "POST",
      body: "{\ninvalid",
    });
    equal((await malformed.json()).error.code, -32700);
    const stringId = await post({
      jsonrpc: "2.0",
      id: "client-1",
      method: "todo.list",
    });
    equal((await stringId.json()).id, "client-1");
    const numericId = await post({
      jsonrpc: "2.0",
      id: 1.5,
      method: "todo.list",
    });
    equal((await numericId.json()).id, 1.5);
    const batch = await post([
      {
        jsonrpc: "2.0",
        id: "a",
        method: "todo.add",
        params: { title: "Batch" },
      },
      {
        jsonrpc: "2.0",
        method: "todo.add",
        params: { title: "Powiadomienie" },
      },
      { jsonrpc: "2.0", id: "b", method: "todo.list" },
    ]);
    const replies = await batch.json() as RpcReply[];
    equal(replies.map((reply) => reply.id), ["a", "b"]);
    equal(replies[1].result?.tasks.at(-1)?.title, "Powiadomienie");
    const notification = await post({
      jsonrpc: "2.0",
      method: "todo.add",
      params: { title: "Bez ID" },
    });
    equal(notification.status, 204);
    equal(await notification.text(), "");
    const notifications = await post([{ jsonrpc: "2.0", method: "todo.list" }]);
    equal(notifications.status, 204);
    await notifications.arrayBuffer();
    const concurrent = await Promise.all(
      Array.from(
        { length: 12 },
        (_, index) => rpc("todo.add", { title: `Równoległe ${index}` }),
      ),
    );
    assert(concurrent.every((reply) => reply.result));
    const final = (await rpc("todo.list")).result!.tasks;
    equal(final.length, 17);
    equal(new Set(final.map((task) => task.id)).size, 17);
    for (let index = 0; index < 12; index++) {
      assert(final.some((task) => task.title === `Równoległe ${index}`));
    }
    const badMethod = await fetch(base + "/rpc");
    equal(badMethod.status, 405);
    await badMethod.text();
    const missing = await fetch(base + "/missing");
    equal(missing.status, 404);
    await missing.text();
    for (const task of final) {
      assert((await rpc("todo.remove", { id: task.id })).result);
    }
    equal((await rpc("todo.list")).result, { tasks: [] });
    assert((await page("/")).includes("Czysta karta"));
  } finally {
    await app.close();
  }
});
