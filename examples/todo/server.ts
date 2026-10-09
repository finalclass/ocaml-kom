import { Backend } from "./bridge.ts";
import { errorPage, listPage, newPage, type Task } from "./pages.ts";

function response(body: string, type: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: { "Content-Type": type, "Cache-Control": "no-store" },
  });
}

export function startServer(port = 8080) {
  const backend = new Backend();
  const server = Deno.serve({ hostname: "127.0.0.1", port }, async (req) => {
    const path = new URL(req.url).pathname;
    try {
      if (path === "/rpc" && req.method === "POST") {
        const text = await req.text();
        if (text.length > 65536) {
          return new Response("Request too large", { status: 413 });
        }
        let compact: string;
        try {
          compact = JSON.stringify(JSON.parse(text));
        } catch {
          compact = "!invalid-json";
        }
        const result = await backend.request(compact);
        return result === null
          ? new Response(null, { status: 204 })
          : response(JSON.stringify(result), "application/json; charset=utf-8");
      }
      if (req.method !== "GET") {
        return new Response("Method not allowed", {
          status: 405,
          headers: { Allow: path === "/rpc" ? "POST" : "GET" },
        });
      }
      if (path === "/") {
        const result = await backend.request(JSON.stringify({
          jsonrpc: "2.0",
          id: "render-list",
          method: "todo.list",
          params: {},
        })) as { result?: { tasks: Task[] }; error?: { message: string } };
        if (!result.result) {
          throw new Error(result.error?.message ?? "Brak listy zadań.");
        }
        return response(
          listPage(result.result.tasks),
          "text/html; charset=utf-8",
        );
      }
      if (path === "/new") {
        return response(newPage(), "text/html; charset=utf-8");
      }
      if (path === "/style.css" || path === "/app.js") {
        const body = await Deno.readTextFile(
          new URL("." + path, import.meta.url),
        );
        return response(
          body,
          path.endsWith(".css")
            ? "text/css; charset=utf-8"
            : "text/javascript; charset=utf-8",
        );
      }
      if (path === "/rpc") {
        return new Response("Use POST", {
          status: 405,
          headers: { Allow: "POST" },
        });
      }
      return new Response("Nie znaleziono strony.", { status: 404 });
    } catch (error) {
      console.error(error);
      return response(
        errorPage("Backend jest niedostępny. Sprawdź terminal serwera."),
        "text/html; charset=utf-8",
        503,
      );
    }
  });
  return {
    server,
    async close() {
      await server.shutdown();
      await backend.close();
    },
  };
}

if (import.meta.main) {
  const port = Number(Deno.args[0] ?? "8080");
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error("Port must be between 1 and 65535");
  }
  const app = startServer(port);
  let closing = false;
  const close = async () => {
    if (closing) return;
    closing = true;
    await app.close();
    Deno.removeSignalListener("SIGINT", close);
    Deno.removeSignalListener("SIGTERM", close);
  };
  Deno.addSignalListener("SIGINT", close);
  Deno.addSignalListener("SIGTERM", close);
}
