const commit = "d38f1b374bed3e31551832ba760970ed821a2b33";
const source = ".local/szaniec-source";
await Deno.mkdir(".local/tmp", { recursive: true });
await Deno.mkdir(".local/bin", { recursive: true });
async function run(cmd: string, args: string[], cwd?: string) {
  const p = await new Deno.Command(cmd, { args, cwd, stdout: "inherit", stderr: "inherit", env: { TMPDIR: Deno.cwd() + "/.local/tmp" } }).output();
  if (!p.success) throw new Error(cmd + " exited " + p.code);
}
try { await Deno.stat(source + "/.git"); }
catch (e) {
  if (!(e instanceof Deno.errors.NotFound)) throw e;
  const temp = await Deno.makeTempDir({ dir: ".local", prefix: "szaniec-fetch-" });
  try {
    await run("git", ["init", "-q"], temp);
    await run("git", ["fetch", "-q", "--depth=1", "https://github.com/finalclass/szaniec.git", commit], temp);
    await run("git", ["checkout", "-q", "--detach", "FETCH_HEAD"], temp);
    await Deno.rename(temp, source);
  } catch (e) { await Deno.remove(temp, { recursive: true }); throw e; }
}
const revision = await new Deno.Command("git", { args: ["rev-parse", "HEAD"], cwd: source, stdout: "piped" }).output();
if (new TextDecoder().decode(revision.stdout).trim() !== commit) throw new Error("Unexpected Szaniec source revision");
await run("dune", ["build", "--root", ".", "bin/szaniec.exe"], source);
const link = ".local/bin/szaniec";
try { await Deno.remove(link); } catch (e) { if (!(e instanceof Deno.errors.NotFound)) throw e; }
await Deno.symlink("../szaniec-source/_build/default/bin/szaniec.exe", link);
console.log("Szaniec v0.1.0-20-gd38f1b3 ready");
