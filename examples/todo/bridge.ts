export class Backend {
  #child: Deno.ChildProcess;
  #writer: WritableStreamDefaultWriter<Uint8Array>;
  #lines: AsyncIterator<string>;
  #queue: Promise<unknown> = Promise.resolve();
  #closed = false;

  constructor() {
    this.#child = new Deno.Command(
      "_build/default/examples/todo/backend.exe",
      { stdin: "piped", stdout: "piped", stderr: "inherit" },
    ).spawn();
    this.#writer = this.#child.stdin.getWriter();
    this.#lines = lines(this.#child.stdout);
  }

  request(text: string): Promise<unknown> {
    const pending = this.#queue.then(async () => {
      if (this.#closed) throw new Error("Backend is closed");
      await this.#writer.write(new TextEncoder().encode(text + "\n"));
      const response = await this.#lines.next();
      if (response.done) throw new Error("Backend exited before replying");
      return JSON.parse(response.value);
    });
    this.#queue = pending.catch(() => {});
    return pending;
  }

  async close() {
    await this.#queue;
    this.#closed = true;
    await this.#writer.close();
    await this.#lines.return?.();
    const status = await this.#child.status;
    if (!status.success) throw new Error(`Backend exited with ${status.code}`);
  }
}

async function* lines(stream: ReadableStream<Uint8Array>) {
  const reader = stream.pipeThrough(new TextDecoderStream()).getReader();
  let buffer = "";
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += value;
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        yield buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
      }
    }
    if (buffer !== "") throw new Error("Incomplete backend response");
  } finally {
    await reader.cancel();
    reader.releaseLock();
  }
}
