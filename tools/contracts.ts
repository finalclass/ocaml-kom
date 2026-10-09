const write = Deno.args.includes("--write");
const projects = [{ source: "contracts", target: "generated/ocaml" }, { source: "examples/contracts", target: "examples/generated" }];
for (const project of projects) {
  const temp = await Deno.makeTempDir({ prefix: "kom-contracts-" });
  try {
    const p = await new Deno.Command("dune", { args: ["exec", "--", "cyrograf", "build", project.source, "--output", temp + "/generated", "--targets", "ocaml"], stdout: "inherit", stderr: "inherit" }).output();
    if (!p.success) throw new Error("Cyrograf exited " + p.code);
    const paths = new Set<string>();
    for await (const f of Deno.readDir(temp + "/generated/ocaml")) {
      if (!f.name.endsWith(".ml") && !f.name.endsWith(".mli")) continue;
      paths.add(f.name);
      const expected = await Deno.readTextFile(temp + "/generated/ocaml/" + f.name);
      const dest = project.target + "/" + f.name;
      if (write) await Deno.writeTextFile(dest, expected);
      else if (await Deno.readTextFile(dest) !== expected) throw new Error("Stale generated source: " + dest);
    }
    for await (const f of Deno.readDir(project.target)) {
      if ((f.name.endsWith(".ml") || f.name.endsWith(".mli")) && !paths.has(f.name)) throw new Error("Unexpected generated source: " + f.name);
    }
    if (project.source === "contracts") {
      for (const name of ["schema.json", "manifest.json"]) {
        const expected = await Deno.readTextFile(temp + "/generated/" + name);
        if (write) await Deno.writeTextFile("generated/" + name, expected);
        else if (await Deno.readTextFile("generated/" + name) !== expected) throw new Error("Stale descriptor: " + name);
      }
    }
  } finally { await Deno.remove(temp, { recursive: true }); }
}
