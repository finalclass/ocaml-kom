document.querySelectorAll("form[data-rpc]").forEach((form) => {
  let pending = false;
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (pending) return;
    pending = true;
    const error = document.getElementById("error");
    const button = form.querySelector('button[type="submit"]');
    button.disabled = true;
    error.hidden = true;
    try {
      const response = await fetch("/rpc", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: crypto.randomUUID(),
          method: form.dataset.rpc,
          params: Object.fromEntries(new FormData(form)),
        }),
      });
      if (!response.ok) throw new Error("Nie udało się wysłać żądania.");
      const result = await response.json();
      if (result.error) throw new Error(result.error.message);
      window.location.assign("/");
    } catch (failure) {
      error.textContent = failure.message;
      error.hidden = false;
      pending = false;
      button.disabled = false;
    }
  });
});
