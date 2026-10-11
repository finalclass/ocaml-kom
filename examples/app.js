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
      const params = Object.fromEntries(new FormData(form));
      form.querySelectorAll('input[type="number"]').forEach((input) => {
        params[input.name] = Number(input.value);
      });
      form.querySelectorAll('input[type="checkbox"]').forEach((input) => {
        params[input.name] = input.checked;
      });
      const response = await fetch(`${document.body.dataset.base}/rpc`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: crypto.randomUUID(),
          method: form.dataset.rpc,
          params,
        }),
      });
      if (!response.ok) throw new Error("Nie udało się wysłać żądania.");
      const result = await response.json();
      if (result.error) throw new Error(result.error.message);
      window.location.assign(`${document.body.dataset.base}/`);
    } catch (failure) {
      error.textContent = failure.message;
      error.hidden = false;
      pending = false;
      button.disabled = false;
    }
  });
});
