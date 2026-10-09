for (const form of document.querySelectorAll("form[data-rpc]")) {
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const error = form.querySelector(".error");
    const button = form.querySelector("button[type=submit]");
    const fields = new FormData(form);
    const method = form.dataset.rpc;
    const params = method === "todo.add"
      ? { title: fields.get("title") }
      : { id: Number(fields.get("id")) };
    error.hidden = true;
    button.disabled = true;
    try {
      const response = await fetch("/rpc", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: crypto.randomUUID(),
          method,
          params,
        }),
      });
      if (!response.ok) {
        throw new Error("Nie udało się połączyć z serwerem. Spróbuj ponownie.");
      }
      const result = await response.json();
      if (result.error) throw new Error(result.error.message);
      globalThis.location.assign("/");
    } catch (failure) {
      error.textContent = failure.message ?? "Nie udało się zapisać zmiany.";
      error.hidden = false;
      button.disabled = false;
    }
  });
}
