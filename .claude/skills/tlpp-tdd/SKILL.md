---
name: tlpp-tdd
description: Use when a new ADVPL/TLPP function or customization is going to be written for Protheus and the tests should come first — "criar feature", "nova funcao TLPP", "TDD para X", "implementar funcao em TLPP". Use also when the user grants the toolchain by name instead of naming an action ("pode usar o tlpp runner nesse projeto"), which is the entry point that routes to tlpp-build, tlpp-test, tlpp-tdd-project-init or tlpp-tdd-setup. Use proactively when the user starts implementing an ADVPL/TLPP function without mentioning tests.
---

The unit of work is **ONE TLPP function at a time** (`user function <prefixo><Nome>`). For each target function the cycle is:

1. **Understand** the function (signature, dependencies, contract)
2. **Systematic brainstorm** of test cases before coding (critical — do not skip)
3. **Red** — write ALL planned tests at once, confirm every one fails
4. **Green** — implement the minimal source that passes all of them
5. **Refactor** with regression guard

**Do not stop at the first failure.** Iterate until every case is green or until the user aborts.

## Where you are running (read this before touching paths)

This skill runs in TWO different contexts. Decide which one you are in before writing a single path:

- **Consumer project** (the normal case): any ADVPL/TLPP repo that has the `tlpp-tdd`
  plugin installed. The runner scripts live under `$env:CLAUDE_PLUGIN_ROOT\runner`,
  never in `.\runner`. Folder layout and the function-name prefix are **whatever
  the project already uses** — read the repo before assuming. If the project has no
  test folders yet, propose a layout instead of inventing one silently.
- **The `tlpp-runner` dev repo itself**: `.\runner` exists, and the conventions below
  (`tec` prefix, `src/`, `test/unit/`, `test/integracao/`) are literal.

Every `tec<Nome>` in the examples below is the **tlpp-runner repo's** prefix, used
here to keep the samples concrete. In a consumer project substitute the project's
own prefix and paths. Getting this wrong produces sources nobody can find and a
`u_` function name that does not match the customer's standard.

If the project has integration tests but no `.tlpp-tdd.json`, stop and run the
`tlpp-tdd-project-init` skill first — there is no test database otherwise.

## Routing (when the user named the toolchain, not a task)

The user says "pode usar o tlpp runner nesse projeto" — a grant, not a task. Read the
repo, then hand off:

| What you find | Go to |
|---|---|
| No `.tlpp-tdd.json` and the work needs a database | `tlpp-tdd-project-init` |
| `~/.claude/tlpp-tdd/config.ps1` missing, or the runner answers HTTP 0 | `tlpp-tdd-setup` |
| A source to get into the RPO, nothing to execute | `tlpp-build` |
| Tests that exist and should run | `tlpp-test` |
| A function to write from scratch | stay here, start the cycle below |

State which one you picked and why before acting.

## Language rule (load-bearing)

This SKILL is written in English so that the workflow rules carry across LLMs, but **all ADVPL/TLPP artifacts you produce are in Portuguese**: function names, variable names, test case descriptions, code comments, `ConOut` log messages, error strings, and content of any `docs/*.md` you touch. The Protheus operators and the user are Brazilian and read Portuguese. Producing English `ConOut` or English test descriptions is a defect.

Examples:
- Test fixture name: `user function test_tecCalcCmsn_caminho_feliz_canonico()` (PT description)
- Assert label: `u_tecAssertEq("comissao para faixa alta", 12, nResult)` (PT label)
- Log: `ConOut("[tecCalcCmsn] AVISO: valor negativo - aplicando fallback")` (PT)
- Frontmatter / SKILL.md prose: English (this file)

## Why extensive coverage matters in this context

Protheus customizations run in production with many non-obvious entry points: different companies/branches, missing `MV_*` parameters, deletion-marked records, MVs with wrong types, unstable external URLs, BR vs ISO date formats, operators typing trailing spaces.

A happy-path-only test covers ~10% of what shows up at the customer. The other 90% are edge cases discovered in production — where discovery cost is highest (ticket, hotfix, blocked operator, eroded trust in the integration).

That's why **brainstorming (phase 2) comes before any line of code**. The cost of listing one more case before coding is near zero; the cost of bolting it on after "everything is green" is much higher.

This skill **does not measure line coverage** (irrelevant for spot customizations). It enforces *behavioral coverage* per function: each observable output of the function must be exercised by a test.

## Why TDD works especially well with an LLM in the loop

Plain LLM coding tends to produce *plausible-looking* code that passes superficial review but breaks in production. TDD changes the game because:

1. **Tests are the objective spec.** When the LLM (you) generates code, the test suite is what determines "done" — not your subjective sense of completion. This removes the "hallucinated success" failure mode where the model declares victory without verification.
2. **Phase ordering blocks scope creep.** Forcing red-before-green prevents the implementer-self from quietly reshaping the test to match what got coded.
3. **Tight feedback loop matches LLM strengths.** Write code → run test → read result → adjust. Each iteration is small and observable. The `/runner/exec` route returns `result=.T./.F.` in <1s, which is exactly the kind of loop where an LLM excels.
4. **Tests caught in code review survive refactor.** Once green, you can refactor aggressively (extract helpers, rename, simplify) and the test suite catches regressions.

The flip side — and the reason this skill is opinionated — is that LLM-generated tests often fail in characteristic ways: they test implementation details, they duplicate the same scenario in different words, they assert too loosely. The phase 2 brainstorm exists to combat that.

## The Iron Law

```
NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST
```

If you wrote source before writing the test that drives it, **delete the source and start over**. No exceptions:
- Don't keep it as "reference" — you'll subconsciously adapt the test to it.
- Don't "adapt" it while writing tests — that's tests-after wearing a TDD costume.
- Delete means delete.

**If you didn't watch the test fail, you don't know if it tests the right thing.** A test that passes the moment it is written proves nothing — it may be exercising code that already does the thing, or it may be tautological.

Common rationalizations and the reality:

| Rationalization                                    | Reality                                                              |
|----------------------------------------------------|----------------------------------------------------------------------|
| "I already manually tested via /tlpp-exec"          | Ad-hoc. No record. Can't re-run after every change.                  |
| "I already wrote X lines, deleting is wasteful"    | Sunk cost. Keeping untested code is the actual waste.                |
| "Tests-after will be the same"                      | No. Tests-after answer "what does this do?". Tests-first: "what should this do?" — biased by your implementation otherwise. |
| "Too simple to need a test"                         | Simple code breaks in production for non-simple reasons (filial, deletado, MV faltando). |
| "TDD slows me down"                                  | TDD beats debugging-in-production. Pragmatic == test-first.           |

If you find yourself reaching for any of these — stop. That's the signal you're skipping the discipline.

## Test-behavior, not implementation

The **seam** under test is always the public contract of `u_tec<Nome>` — its parameters, return value, and observable side effects (a `ConOut` line, a row in `Z_TST_*`). Tests live at that seam; the internals behind it can change entirely without a single test changing.

A critical rule when writing the tests: **assert what the function returns or causes (observable behavior), not how it computes it.**

- ✅ `u_tecAssertEq("comissao retornada", 12.5, u_tecCalcCmsn(1000, "A"))` — asserts the contract
- ✅ `u_tecAssertTrue("logou aviso", "AVISO: valor negativo" $ u_tecLastConOut())` — asserts an observable side effect
- ❌ `u_tecAssertEq("variavel interna nIndice", 3, ...)` — asserts implementation
- ❌ Testing that a specific `static function` was called — testing the shape of code, not the contract

If you cannot test the behavior without reaching into internals, **listen to the test**: the function is probably doing too much, or its dependencies are wrong. Refactor the production code so the behavior is reachable from the outside (extract internal concerns into their own `user function tec*` with their own contracts) rather than weaken the test.

Name each case for the **behavior** it specifies, never the mechanism: `test_tecCalcCmsn_tipo_B_aplica_metade` (WHAT), not `test_tecCalcCmsn_chama_getmv_e_multiplica` (HOW).

### Tautological tests (the LLM signature failure)

A test is **tautological** when the expected value is recomputed the same way the code computes it — it passes by construction and can never disagree with the implementation. Expected values must come from an **independent source of truth**: a known-good literal, a worked example done by hand, the customer's spec.

```tlpp
// TAUTOLOGICO: esperado recalculado com a MESMA formula do fonte
nEsperado := nValor * u_tecGetMv("MV_TEC_CMS", 5) / 100
u_tecAssertEq("comissao", nEsperado, u_tecCalcCmsn(nValor, "A"))

// CORRETO: literal conhecido, calculado a mao a partir da regra do dominio
u_tecAssertEq("comissao de 1000 tipo A (5%)", 50, u_tecCalcCmsn(1000, "A"))
```

Related: when the project already has a **reader** function for the state under test, verify through it instead of through a side channel — `u_tecBuscaCli` after the write, not a `SELECT` direct at the table. Direct SQL verification (`u_tecQryFirst`) is legitimate only when the written row IS the contract and no reader exists.

## Pre-flight (once per session)

- Resolve the runner path first (plugin install first, in-repo fallback) — `.\runner\` only exists in the tlpp-runner dev repo, in a consumer project the scripts live under the plugin root:

  ```powershell
  $runner = if ($env:CLAUDE_PLUGIN_ROOT) { "$env:CLAUDE_PLUGIN_ROOT\runner" } else { '.\runner' }
  ```

  Every command below uses `$runner` instead of `.\runner`.
- `& "$runner\Invoke-TlppRunner.ps1" -Ping` should return HTTP 200. Otherwise ask the user to start the dev AppServer and stop.
- If you have not read `docs/LLM-WORKFLOW.md` in this session, read it now — it documents the low-level APIs (available asserts, wrappers, DB helpers) which this skill references but does not duplicate.

## Phase 1 — Understand the target function

Before brainstorming any case, clarify with the user:

1. **Name** — `tec` prefix required (e.g. `tecCalcCmsn`, `tecBuscaCli`)
2. **Signature**: parameters (name, type, optional/required, default value) + return (type, expected shape)
3. **Expected behavior in 1–2 sentences** — what the function does on the happy path
4. **External dependencies** — each one becomes a mock. Make the list explicit:
   - `DbSeek` on some table? Which one? → will need `u_tecDbSeekFld`
   - `TCQuery` SQL? Which SELECT? → will need `u_tecQryFirst` / `u_tecQryAll`
   - `GetMv`/`GetNewPar` for some parameter? Which key? → will need `u_tecGetMv`
   - `FWRest` hitting a URL? Which endpoint? → will need `u_tecHttpReq`
   - `Date()`/`Time()` affecting logic? → `u_tecHoje` / `u_tecHora`
   - Calls another `user function` of this project? Prefer NOT to mock it — test indirectly
5. **Suite**: `unit` (no DB, mocks) or `integracao` (real `PROTHEUS_TST`)
6. **New table needed?**
   - Ad-hoc within the test → `u_tecTstCreateTable` inside the test
   - Reusable across tests → `/tlpp-table create Z_TST_NOME "..."` beforehand
7. **New field / parameter / index (SX3/SX6/SIX)?** NEVER create from source. Register in `.claude/plans/<slug>/pre-producao.md` (create if missing) and ask the user to add it via Configurador.

## Phase 2 — Systematic brainstorming of test cases

**This is the phase that differentiates this skill.** Apply every filter below in order. For each category decide explicitly whether it applies. If you skip a category, justify it briefly in your output.

Aim for **8–15 test cases for an average function**. Fewer than 5 is a smell — you're probably missing categories. More than 20 usually means the function is doing too much and should be split.

### 2a. Mandatory checklist (applies to every function)

- [ ] **Canonical happy path** — one canonical case from the domain
- [ ] **Alternative happy path** — one valid case with variation (different tier, different type, different valid path)
- [ ] **Parameter nil / not passed** — if there is a `DEFAULT`, test the default kicks in; otherwise test the resulting behavior (error? empty return?)
- [ ] **Empty parameter** — string `""`, array `{}`, JsonObject with no properties
- [ ] **Numeric boundary** — 0, -1, domain minimum, known domain maximum
- [ ] **Return: expected shape** — beyond the value, assert the TYPE (`ValType` or JsonObject shape)

### 2b. Heuristics by dependency (only if applicable)

For each dependency you listed in phase 1, add the cases:

| Dependency             | Cases to cover                                                                |
|------------------------|-------------------------------------------------------------------------------|
| `DbSeek` on a table    | "registro nao encontrado" + "registro encontrado com campo vazio"             |
| `TCQuery`              | "0 linhas" + "multiplas linhas" + (if relevant) "erro SQL"                    |
| `GetMv` / `GetNewPar`  | "parametro inexistente (usa default)" + "parametro com valor explicito"       |
| `FWRest` (via wrapper) | HTTP 200 + 4xx + 5xx + (if relevant) timeout / network error                  |
| `Date()` / `Time()`    | mock a known fixed date via `u_tecMkHoje` if logic depends on the date        |
| Another user function  | prefer NOT to mock it — exercise it indirectly                                |

### 2c. Protheus-specific heuristics

- Function touches records? Add "registro deletado (`D_E_L_E_T_ = '*'`)" — verify the filter
- Multi-company / multi-branch? "filial diferente da corrente" + "filial em branco"
- Monetary calculation? "arredondamento de centavos" + "valor negativo" + (if applicable) "valor zero"
- Date manipulation? "virada de mes" + "ano bissexto (29/02)" + "data invalida (string vazia ou formato BR vs ISO)"
- Concatenates `ALIAS->CAMPO`? Make sure the source uses `u_tecDbSeekFld` — otherwise the mock cannot intercept

### 2d. Error-guessing heuristics

- Could the operator type something invalid? (formato BR `01/05/2026` vs ISO `2026-05-01`, trailing space, casing)
- Running twice in a row produces the same result? (idempotence — relevant for integrations)
- Two threads calling concurrently? (rare for typical customizations, but worth a thought for write operations)

### 2e. Output of phase 2 — named list of cases

Present to the user BEFORE writing any test:

```
Casos planejados para tec<Nome>:
 1. test_tec<Nome>_caminho_feliz_canonico       — entrada X -> retorna Y
 2. test_tec<Nome>_caminho_feliz_faixa_alta     — entrada X' -> retorna Y'
 3. test_tec<Nome>_param_nil_aplica_default     — nil -> default 0
 4. test_tec<Nome>_param_string_vazia           — "" -> retorno definido
 5. test_tec<Nome>_boundary_zero                — 0 -> retorno definido
 6. test_tec<Nome>_registro_nao_encontrado      — DbSeek mockado vazio
 7. test_tec<Nome>_http_4xx                     — 4xx -> log + retorno nil
 8. test_tec<Nome>_http_5xx                     — 5xx -> log + retorno nil
 9. test_tec<Nome>_data_invalida                — string "" -> fallback
```

**Do not proceed without explicit user confirmation.** The user has more domain context than you and may add or remove cases. Accept the criticism — if they say "case 5 is overkill", remove it. If they add "case 10: cliente bloqueado", add it.

## Phase 3 — Red

Once the list is confirmed, write ALL the tests in the test file in one shot (batched red), then move to green. For very large functions (>10 cases) it is also valid to do 1–2 cases per iteration.

**The batch is an economy, not a contract.** Classic TDD works in vertical slices (one test → one implementation → repeat) because each cycle teaches you something; batching all tests up front risks specifying *imagined* behavior. Here the 37–93s compile window makes strict one-test cycles too expensive, so we batch per function — but treat every test written ahead as a **tracer bullet subject to revision**: when a green cycle reveals that a planned case assumed behavior the domain doesn't want, revise that case (and tell the user) before continuing. Batched red never overrides what the implementation just taught you.

### 3a. Write the tests

File: `test/unit/tec<Nome>Tst.tlpp` (or `test/integracao/tec<Nome>ItgTst.tlpp`).

#### Test file template (load-bearing)

**Every** test file MUST open with these three lines — once, at the very top, before any `@TestFixture`. Without `#include "tlpp-probat.th"` the `@TestFixture()` annotation fails to compile with `Annotation @TESTFIXTURE not defined` and the whole file is dead on the first pass:

```tlpp
#include "tlpp-core.th"
#include "tlpp-probat.th"
using namespace tlpp.probat
```

Then, **per case**, append one fixture (the 3-line header above is NOT repeated):

```tlpp
@TestFixture()
user function test_tec<Nome>_<caso>()
    u_tecAssertReset()                  // mandatory FIRST line of every case
    u_tecTstStart()                     // BEFORE any u_tecMk* - Start CREATES the mock stores; a mock set before it returns .F. and is silently lost
    // arrange (mocks: u_tecMkSql / u_tecMkBdSeek / u_tecMkMv / u_tecMkHttp / u_tecMkHoje / ...)
    // act
    // assert (multiple asserts per case are welcome — describe each one in PT)
    u_tecTstStop()
return u_tecAssertsOk()                 // mandatory LAST line — reflects asserts via /runner/exec
```

So a file with N cases = the 3-line header **once** + N `@TestFixture` blocks.

Use `mcp__file-tools__write_file` with `encoding=cp1252`. **Never the native `Write`** — it corrupts CP1252 and the compile breaks.

### 3b. Confirm every case fails (the red gate)

For each case, in sequence:

```powershell
& "$runner\Invoke-TlppRunner.ps1" -Function u_test_tec<Nome>_<caso> -Quiet
```

Expected outcome at this stage: one of the two healthy reds below. How to read each outcome:

| Outcome at red                                | Diagnosis                                    | Action                                                |
|-----------------------------------------------|----------------------------------------------|-------------------------------------------------------|
| `u_test_x: ERRO InterFunctionCall: cannot find function U_TEC<NOME>` | Healthy red: the target function does not exist yet | Proceed |
| `result=.F.` with `FAIL:` lines naming the expected behavior | Healthy red: the function exists but does not do this yet | Proceed |
| `result=.T.` (passes immediately)              | You're testing existing behavior, or the assertion is tautological | Fix the test — make it actually assert something the target function doesn't do yet |
| Compile fails (`[FATAL]` in log)               | Test syntax error                            | Fix the test, recompile (`& "$runner\Invoke-TlppBuild.ps1" -File <arquivo>`), re-run. Do NOT keep going with a broken test |
| Any other `ERRO` whose stack points at the test or at a mock (`u_tecMk*`, `u_tecTstStart`) | Mock setup wrong, or the test itself is broken | Fix the test, re-run |

**Do not proceed to green until every test has been observed to fail for the right reason.** Otherwise you risk a green that's an artifact of a broken test rather than a working implementation.

## Phase 4 — Green

Implement `src/tec<Nome>.tlpp` with the minimal code that passes all the cases. Reminders:

- **`user function tec<Nome>`** always (never bare `function` — that requires the TOTVS portal JWT)
- **Every external dependency goes through a wrapper** in `src/tecWrap.tlpp` — otherwise mocks cannot intercept:
  - `DbSeek + ALIAS->CAMPO` → `u_tecDbSeekFld(...)`
  - `TCQuery` → `u_tecQryFirst(...)` or `u_tecQryAll(...)`
  - `GetMv` / `GetNewPar` → `u_tecGetMv(...)`
  - `FWRest` (any verb) → `u_tecHttpReq(...)`
  - `Date()` / `Time()` → `u_tecHoje()` / `u_tecHora()`
- Encoding CP1252 mandatory (use `mcp__file-tools__write_file`)
- Compilation is explicit: after saving, run `& "$runner\Invoke-TlppBuild.ps1" -File src\tec<Nome>.tlpp` (or let `/tlpp-test` compile before running)
- **Business rules without explicit customer source** (block / reject behavior): do NOT decide on a hunch. Apply a permissive fallback + log + TODO in `.claude/plans/<slug>/perguntas-cliente.md`. See the project's global instruction `regras-de-negocio-vem-do-cliente`.

Then re-run every case. For each `.F.` or `EXC`:

1. Read the `FAIL:` lines in the runner output. `/runner/exec` returns the assert summary (`asserts` field), and `-Quiet` prints the score plus one line per failed assert — no need to open `console.log`:
   ```
   u_test_x: result=.F. dur=0.002s asserts=1ok/2fail
     FAIL: soma errada | expected=3 actual=2
   ```
2. `connection refused` right after a build: every compilation (any source, not only `@Get/@Post`) takes HTTPREST down until the next `[ONSTART] RefreshRate` cycle (~5s after the build with `RefreshRate=2`). The runner already waits; do not retry by hand
3. Runtime error (`u_x: ERRO <message>`, HTTP 500 `error=runtime`): the runner prints the first stack lines with source and line, plus the `FAIL`s recorded before the error. **Fix the source, never the test.** The test is the spec. Only a generic `{"code":500,"message":"Internal Server Error"}` (explicit `Break()` in the called code, or an error that kills the thread such as `Empty()` on a JsonObject) needs `console.log`/`error.log`.
4. Iterate until all `.T.`

### Bounded repair loop (do not infinite-edit)

If the same case stays red after **3 attempts** at fixing the source, **stop and surface the situation to the user**: show the test, the last source attempt, and the relevant log lines. Ask whether the test expectation is wrong (maybe the brainstorm assumed a behavior the domain doesn't actually want) or whether you should keep trying. Blindly editing the source past 3 attempts produces drift, not progress.

### When stuck (decision table)

| Problem                                          | What to do                                                                 |
|--------------------------------------------------|----------------------------------------------------------------------------|
| Don't know how to assert the behavior            | Write the assertion you wish you had first, then make `u_tecAssert*` support it (or use a different assert) |
| Test setup is huge (10+ lines of mocks)          | The function depends on too many things. Split it.                          |
| Need to mock everything to test one thing        | Function too coupled. Promote a dependency to a wrapper, or split.          |
| Mock setup is hard to express                    | The wrapper is missing a case or the dependency wasn't routed through `tecWrap.tlpp`. Fix the wrapper first. |
| Can't reach the behavior from outside the function | Listen to the test — extract an internal concern into its own user function with its own contract |
| Tests pass green but production breaks anyway    | Production code bypasses a wrapper (DbSeek/GetMv/FWRest direct). Find and refactor. |

## Phase 5 — Refactor safely

Once every case is `.T.` you **may** refactor:

- Extract private helpers (`static function`)
- Rename variables (Hungarian notation — `cNome`, `nValor`, `lFlag`, `aLista`, `jObj`, `dData`)
- Reduce duplication
- Replace magic literals with constants

After each refactor change: re-run **every case of the function** + 3–5 neighbouring tests in the project to catch regressions. If something breaks, revert that step.

## Mock anti-patterns specific to this project

The wrappers in `tecWrap.tlpp` ARE the system boundary — DB, SQL, MV parameters, HTTP, clock. **Mock only at that boundary.** Mocking a `tec*` function of the project itself (your own code) is the smell Pocock calls "mocking internal collaborators": exercise it for real and let the wrapper mocks underneath it intercept.

Because the mock surface at that boundary is large, there is room for these specific failure modes:

1. **Asserting on the mock itself instead of on the function's behavior.** A test that checks "did `u_tecMkSql` get configured with this SQL?" is testing the mock infrastructure, not the production function. Assert on the function's *return value* or *observable side effect* (a ConOut line, a record written to a `Z_TST_*` table) — never on the mock.
2. **Partial mock — only the fields the test happens to read.** If the real `SA1` row carries 30 columns and you mock 3, downstream code that reads a 4th column silently gets nil. Mirror the real shape: when mocking via `u_tecMkBdSeed("SA1", aRows)`, include every column the production function might touch — even ones not under test today.
3. **Mocking without understanding the side effects.** Some real calls have side effects (write to DB, set state in another wrapper) that other parts of the same test depend on. Don't mock at a higher level than necessary. If only the slow part is the problem, mock the slow part — not the whole flow.
4. **Mock setup larger than the assertion.** When the mock setup is 20 lines and the assertion is 1, the test is fragile — any change to the function's internals will break it. That's a sign the function is doing too much (split it) or that the test should run as integration with real DB instead of as unit with mocks.
5. **Test-only helpers leaking into `src/`.** If you find yourself adding a function to `src/tec<Nome>.tlpp` that only the test calls (a "reset", "destroy", "inspect"), STOP — move it to `mocks/` or to the test file itself. Production code stays clean.

## Verification checklist (before declaring done)

Run this checklist before reporting completion to the user. If you can't tick every box, you haven't finished — investigate the unchecked item.

- [ ] The test file opens with the 3-line header (`#include "tlpp-core.th"` + `#include "tlpp-probat.th"` + `using namespace tlpp.probat`) — else `@TestFixture` won't compile
- [ ] Every planned case has a `@TestFixture` with `u_tecAssertReset()` and `return u_tecAssertsOk()`
- [ ] Every case was observed to fail for the right reason before any source was implemented (red gate honored)
- [ ] All planned cases return `.T.` now (re-run all of them in sequence — copy the output)
- [ ] 3–5 neighbouring tests in the project still return `.T.` (no regression)
- [ ] Production code is in `src/tec<Nome>.tlpp` with `user function` (not bare `function`)
- [ ] All external dependencies go through wrappers in `tecWrap.tlpp` (no direct `DbSeek` / `GetMv` / `FWRest` / `Date()` in production code)
- [ ] Encoding of every new/edited file is CP1252 (used `mcp__file-tools__write_file`)
- [ ] Test descriptions, `ConOut` messages, variable names, comments are in PT
- [ ] No SX3/SX6/SIX created from source. Anything needed is in `.claude/plans/<slug>/pre-producao.md`
- [ ] No blocking business rule added without explicit customer source. Any uncertain rule is permissive fallback + log + TODO in `.claude/plans/<slug>/perguntas-cliente.md`
- [ ] No test-only helpers leaked into `src/`

Cannot check every box? Don't tell the user "done". Surface what's missing.

## When to stop and how to report

Stop when:
- The verification checklist above is fully ticked
- Every planned case returns `.T.`
- Neighbour suite (3–5 tests) didn't regress
- Refactor (if any) keeps everything green

Output to the user (concise, in PT to match the user's language):

```
Feature tec<Nome> implementada.
Fontes:  src/tec<Nome>.tlpp
Testes:  test/unit/tec<Nome>Tst.tlpp (N casos)
Resultado: N/N .T.
Casos cobertos:
  - caminho feliz canonico
  - caminho feliz alternativo
  - parametro nil aplica default
  - registro nao encontrado
  - http 4xx
  - http 5xx
  - <etc>
Pendencias pre-producao (se houver):
  - <campo/parametro a criar via Configurador, em .claude/plans/<slug>/pre-producao.md>
Perguntas abertas pro cliente (se houver):
  - <em .claude/plans/<slug>/perguntas-cliente.md>
```

**Do not commit without explicit user confirmation.** Ask whether to commit.

## Naming conventions (project shorthand)

| Item                       | Convention                                                       |
|----------------------------|------------------------------------------------------------------|
| Source file                | `src/tec<Nome>.tlpp`                                             |
| Unit test file             | `test/unit/tec<Nome>Tst.tlpp`                                    |
| Integration test file      | `test/integracao/tec<Nome>ItgTst.tlpp`                           |
| User function              | `user function tec<Nome>` (callable as `u_tec<Nome>`)            |
| Test name                  | `user function test_tec<Nome>_<descricao_snake_case>` (PT desc)  |
| Test table                 | `Z_TST_<NOME>` on the `PROTHEUS_TST` database                    |
| Encoding                   | CP1252 (never UTF-8 in `.tlpp` / `.prw`)                         |

## Short end-to-end example (brainstorm → tests → source)

**Target function**: `tecCalcCmsn(nValor, cTipoCliente)` → returns commission percentage based on value and customer type.

**Phase 1 (understand)**:
- params: `nValor` (numeric, required), `cTipoCliente` (char(1), optional, default "A")
- return: numeric, 0..30
- dependencies: `GetMv("MV_TEC_CMS")` (base percentage), no DB
- suite: unit

**Phase 2 (brainstorm)** — 8 cases proposed:

```
1. test_tecCalcCmsn_tipo_A_faixa_baixa       — 100, "A" -> 5
2. test_tecCalcCmsn_tipo_A_faixa_alta        — 10000, "A" -> 12
3. test_tecCalcCmsn_tipo_B_aplica_metade     — 1000, "B" -> 5 (regra)
4. test_tecCalcCmsn_tipo_invalido_fallback   — 1000, "Z" -> usa tipo A
5. test_tecCalcCmsn_valor_zero               — 0 -> 0
6. test_tecCalcCmsn_valor_negativo           — -100 -> 0 + ConOut aviso
7. test_tecCalcCmsn_param_default_tipo       — 1000, nil -> usa "A"
8. test_tecCalcCmsn_mv_inexistente           — MV vazio -> usa default 5%
```

**Phase 3+4** — write all 8 tests, run → all `.F.`, implement `tecCalcCmsn` in ~30 lines, run → all `.T.`.

## Anti-patterns that will bite

| Mistake                                                | Symptom                                  | Fix                                                          |
|--------------------------------------------------------|------------------------------------------|--------------------------------------------------------------|
| Skip phase 2 and code only the happy path              | Bug surfaces in production 2 weeks later | Run the 2a checklist + relevant heuristics every time        |
| Present the case list without asking the user         | Wrong domain assumption baked in         | Wait for explicit confirmation before writing tests          |
| Tests assert implementation details (internal state)   | Test must change every time source does  | Assert the contract / observable behavior                    |
| Expected value recomputed with the source's formula    | Test passes by construction, catches nothing | Independent literal (see Tautological tests above)       |
| LLM-flavored duplicate cases ("the same in 3 words")   | Inflated case count, real coverage low   | Each case must test a distinct branch / boundary             |
| Forget `u_tecAssertReset()` at the top                 | False `.T.` (counter leaks from prev)    | Always first line after `user function test_*`               |
| Forget `return u_tecAssertsOk()` at the bottom         | `.T.` without reflecting any assert      | Always last line                                             |
| Native `Write` on `.tlpp` / `.prw`                     | Encoding corrupted, compile breaks       | `mcp__file-tools__write_file` with `encoding=cp1252`         |
| `Empty(jResp)` directly                                | Crash "unknown variable type"            | `u_tecAssertEmpty/NotEmpty` (type-aware)                     |
| `FWRest` pointing at this same AppServer               | Type-mismatch crash + REST restart       | `u_tecHttpReq` (delegates to `HTTPQuote`)                    |
| Prod code bypasses the wrappers                        | Mocks don't intercept, test is fake green| Refactor to `u_tecDbSeekFld` / `u_tecQryFirst` / `u_tecGetMv`|
| Bare `function` (no `user` / `static`)                 | "Regular functions not allowed"          | `user function` or `static function`                         |
| `as <tipo>` on a var initialized with nil              | "Incompatible types"                     | Omit `as <tipo>` when initializing with nil                  |
| `tlpp.probat.run "type:suite",...`                     | Returns 0/0                              | Use `/tlpp-test <funcao>` instead                            |
| Create SX3/SX6/SIX from source                         | Inconsistent state, no rollback          | Configurador. Register in `.claude/plans/<slug>/pre-producao.md`             |
| Add a blocking rule with no customer source            | Legit order blocked in production        | Permissive fallback + log + TODO in `.claude/plans/<slug>/perguntas-cliente.md` |
| Adjust the test to make it pass                        | False sense of coverage                  | Test is the spec — fix the source                            |
| Keep editing past 3 attempts without surfacing         | Drift instead of progress                | Bounded repair loop — stop and ask the user                  |
| Test descriptions / `ConOut` / variables in English    | Operator can't read logs                 | ADVPL artifacts always in PT (see Language rule above)       |

## Red flags — STOP and start over

If any of these is true, you are not doing TDD. Delete the offending code and restart from the brainstorm.

- You wrote source code before the corresponding test
- The test passed the first time you ran it (and you can't explain why)
- You changed a test to make it pass instead of changing the source
- The brainstorm phase was skipped and you went straight to "happy path test"
- You kept editing the source past 3 failed attempts without surfacing the situation
- You added a method to `src/` that only the test calls
- You're asserting on the mock instead of on what the function returns or causes
- You can't explain in PT what each test case covers in one sentence

## References

- `docs/LLM-WORKFLOW.md` — full APIs (asserts, wrappers, DB helpers, mocks) — read once per session
- `CLAUDE.md` — project conventions and known limitations
- `docs/SETUP.md` — infrastructure troubleshooting (PROBAT discovery, ports, etc.)
- `src/tecAssert.tlpp` — assert implementations
- `src/tecWrap.tlpp` — mockable wrapper implementations
- `mocks/tecMock.tlpp` — mock helpers (`u_tecMk*`)
- `test/integracao/tecTstDbHlp.tlpp` — integration DB helpers
- [mattpocock/skills — engineering/tdd](https://github.com/mattpocock/skills/blob/main/skills/engineering/tdd/SKILL.md) — language-agnostic TDD reference (seams, tautological tests, vertical slices, mocking at system boundaries). This skill specializes those principles for ADVPL/TLPP.
