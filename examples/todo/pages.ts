export type Task = { id: number; title: string };

export function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (char) => {
    return ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;",
    } as Record<string, string>)[char];
  });
}

function layout(title: string, body: string): string {
  return `<!doctype html>
<html lang="pl">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(title)} · Todo</title>
  <link rel="stylesheet" href="/style.css">
  <script type="module" src="/app.js"></script>
</head>
<body>
  <main>
    <header><a class="brand" href="/">todo<span>.</span></a><span class="tagline">Miejsce na małe i duże plany.</span></header>
    ${body}
    <footer>Jedna rzecz naraz.</footer>
  </main>
</body>
</html>`;
}

export function listPage(tasks: Task[]): string {
  const rows = tasks.map((task) => `
    <li class="task">
      <span class="task-id" aria-hidden="true">${
    String(task.id).padStart(2, "0")
  }</span>
      <span class="task-title">${escapeHtml(task.title)}</span>
      <form data-rpc="todo.remove">
        <input type="hidden" name="id" value="${task.id}">
        <button class="remove" type="submit" aria-label="Usuń zadanie: ${
    escapeHtml(task.title)
  }">Usuń</button>
        <p class="error" role="alert" hidden></p>
      </form>
    </li>`).join("");
  return layout(
    "Twoje zadania",
    `
    <div class="heading"><div><p class="eyebrow">TWÓJ PLAN</p><h1>Twoje zadania</h1><p class="muted">${
      tasks.length === 0
        ? "Zrób miejsce na to, co chcesz zrobić."
        : `Liczba zadań: ${tasks.length}`
    }</p></div><a class="button" href="/new">+ Dodaj zadanie</a></div>
    ${
      tasks.length === 0
        ? `<section class="empty"><div class="empty-mark" aria-hidden="true">✓</div><h2>Czysta karta</h2><p>Dodaj pierwsze zadanie i zacznij od małego kroku.</p><a href="/new">Dodaj pierwsze zadanie →</a></section>`
        : `<ol class="tasks">${rows}</ol>`
    }
  `,
  );
}

export function newPage(): string {
  return layout(
    "Nowe zadanie",
    `
    <a class="back" href="/">← Wróć do listy</a>
    <div class="heading"><div><p class="eyebrow">KOLEJNY KROK</p><h1>Nowe zadanie</h1><p class="muted">Co chcesz zrobić?</p></div></div>
    <section class="card">
      <form data-rpc="todo.add">
        <label for="title">Treść zadania</label>
        <input id="title" name="title" type="text" placeholder="Na przykład: kupić mleko" required maxlength="500" autocomplete="off" autofocus aria-describedby="title-help">
        <p class="hint" id="title-help">Krótko i konkretnie. Do 500 bajtów UTF-8.</p>
        <p class="error" role="alert" hidden></p>
        <div class="actions"><button class="button" type="submit">Dodaj zadanie</button><a href="/">Anuluj</a></div>
      </form>
    </section>
  `,
  );
}

export function errorPage(message: string): string {
  return layout(
    "Błąd",
    `<h1>Nie udało się otworzyć strony</h1><p role="alert">${
      escapeHtml(message)
    }</p><a href="/">Spróbuj ponownie</a>`,
  );
}
