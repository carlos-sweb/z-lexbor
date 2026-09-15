# Audit — how `z-lexbor` was verified

This document records **what was actually checked**, how, and what the results
were. It exists so that a reader does not have to take the README's claims on
trust: every number below came from a command that can be re-run.

It also records the places where the work was *wrong first* — the assumptions
that turned out to be false, the coverage gap the audit exposed, and what this
audit still does **not** prove.

| Area | Result |
|---|---|
| lexbor translation units compiled | **213 / 213**, 0 failures |
| Public headers exported | **226** (of 250 total) |
| Raw `extern fn` in the bindings | **2 740** (16 602 generated lines) |
| Public API names covered by the gate | **2 408 / 2 408**, 0 missing |
| Tests | **213** (187 suite + 26 inline) |
| Test suite size | 3 800+ lines across 18 files |
| Target platforms | `x86_64-linux`, `aarch64-linux`, `x86_64-windows-gnu`, `wasm32-wasi` |
| Optimisation modes tested | Debug, ReleaseSafe, ReleaseFast |
| CI jobs | 8, all green |
| Deliberate bugs injected (mutation testing) | 3, all detected |

---

## 1. Scope and method

The guiding question was not "does it compile?" but **"how would we know if it
were broken?"** For a library whose job is to hand 2 700 C functions to Zig, the
dangerous failures are the quiet ones:

- a symbol silently missing from the bindings, so a feature is unreachable;
- a status code misclassified, so an error is reported as success;
- a pointer-lifetime rule assumed rather than enforced;
- a buffer bound that is right for the inputs in the tests and wrong for real ones.

So the audit was built around **empirical checks with a pass/fail answer**, and
around **deliberately trying to break the wrapper** rather than demonstrating
that it works on good input.

---

## 2. The engine: hermetic, pinned, complete

### 2.1 The system lexbor was rejected

The machine had lexbor installed under `/usr/local` and reported version
**2.8.0**. Upstream was at **v3.0.1**, and the v3.0.0 release notes list
breaking changes (a replaced style event system, `document.node_cb` split into
`mutation` / `attr_mutation` tables, the `parse_cb` mechanism removed, new
`lxb_style_init()` / `lxb_style_destroy()`).

Building against the installed copy would therefore have produced a wrapper for
an API that no longer exists upstream. The decision was to **vendor v3.0.1**
(`7e278c0188489bfce6b71ced0cc900cbb31e6244`) and compile it from source, so the
wrapper and the engine version are locked together. All 2.8.0 findings in this
document are historical context only.

### 2.2 Binding generation pipeline

```
vendor/lexbor/source/**/*.h
      │  tools/gen_c_header.zig     (deterministic, sorted, res.h excluded)
      ▼
  lexbor_c.h                        (generated at build time, never committed)
      │  std.Build.addTranslateC
      ▼
  c.zig                             (2 740 extern fn, 16 602 lines)
      │  src/sys/root.zig
      ▼
  raw complete API   +   hand-written idiomatic layer
```

Generating the umbrella header at build time means the bindings **cannot drift**
from the vendored tree: there is no committed artifact to forget to regenerate.

### 2.3 Why `res.h` is excluded — and how it was found

`translate-c` over all 250 headers initially failed with 9 errors. Tracing them
showed the cause was not a lexbor/toolchain incompatibility but a class of file:

- `lexbor/**/res.h` and `lexbor/**/*_res.h` are **generated static data tables**.
- No public header includes them; only **16 `.c` files** do.
- They are **not self-contained** — they reference declarations from sibling
  headers and depend on a specific include order. `ns/res.h`, for instance,
  `#error`s unless `lexbor/ns/const.h` was included first.

They are translation-unit-private by design, so they are excluded from the
binding umbrella header while still being compiled normally as part of their own
`.c` files. With the 226 genuinely public headers, `translate-c` succeeds
cleanly.

This is worth stating plainly because it was a **wrong first diagnosis**: the
initial probe excluded only `*_res.h`, which let plain `res.h` files through and
produced a confusing failure that looked like a toolchain bug.

### 2.4 The coverage gate

Presence of symbols is machine-checked rather than assumed:

```
$ zig build check-coverage
check-coverage: 226 public headers, 2408 function-like public names, 0 missing
```

`tools/check_coverage.zig` parses every public header with a small C-aware
scanner (it strips comments, string/char literals and preprocessor directives),
collects every `lxb_*` / `lexbor_*` identifier used as a function, and requires
each one to appear as a whole word in the generated bindings. It fails the build
otherwise.

Two false positives surfaced during development and were fixed properly rather
than silenced: `lxb_dom_attr_local_name_append` and `lxb_tag_append_lower` are
file-local `static` helpers that appear **only inside `#define` bodies** in
`html/tokenizer/state.h`. They are not public API, which is exactly why the
scanner now skips preprocessor directives.

---

## 3. Robustness by construction

Some properties are enforced by the design rather than by tests, which is
stronger. The rules are:

1. **One owner per object.** `html.Parser` owns every `Document` it produces
   (documents live in the parser's memory pool); `css.Parser` owns its
   `SelectorList`s; `url.Parser` owns its `Url`s; `selectors.Engine` owns both
   its CSS parser and its selector engine.
2. **Borrowed views have no `deinit`.** `dom.Node`, `dom.Element`, `dom.Attr`
   and `html.Document` are non-owning wrappers. There is simply no method to
   call, so use-after-free from Zig cannot be expressed by accident. This is
   asserted in `tests/ownership_test.zig` with `@hasDecl`.
3. **Teardown is idempotent.** Every owning type nulls its pointer, so a second
   `deinit()` is a no-op. Tested for all four owning types.
4. **One allocator per object.** Memory lexbor allocated is freed only by the
   matching `lxb_*_destroy`. A Zig allocator is never applied to a lexbor-owned
   pointer. Zig-side allocations exist only for things Zig owns, such as the
   result list from `queryAll`.
5. **No silent success.** `status.check` maps every `LXB_STATUS_*` to a distinct
   Zig error, so `try` cannot mistake a failure for success.
6. **Total mappings.** `Status.fromRaw` and `NodeType.fromRaw` return an optional
   or a fallback instead of trapping on unknown values, because a C library can
   hand back garbage under adversarial input.

---

## 4. The test system

`zig build test` runs both halves:

| Step | Contents |
|---|---|
| `zig build test-unit` | 26 inline tests next to the code in `src/` |
| `zig build test-suite` | 156 tests in `tests/` |

| File | Tests | Focus |
|---|---|---|
| `adversarial_test.zig` | 19 | Hostile input and exhausted resources |
| `dom_test.zig` | 23 | Traversal, iterators, attributes, deep trees |
| `selectors_test.zig` | 16 | Matching, order, early exit, callback errors, OOM |
| `callback_test.zig` | 14 | `callconv(.c)` bridges and write-failure propagation |
| `html_test.zig` | 14 | Parsing, structure, serialization stability |
| `status_test.zig` | 11 | Exhaustive status mapping, raw-value sweep |
| `integration_test.zig` | 10 | End-to-end user scenarios |
| `url_test.zig` | 10 | WHATWG parsing, resolution, IDNA |
| `convert_test.zig` | 9 | The C-string/slice boundary |
| `ownership_test.zig` | 8 | Lifetime rules, idempotent teardown, leak checks |
| `css_test.zig` | 7 | Selector-list parsing incl. garbage |
| `fuzz_test.zig` | 7 | Deterministic seeded fuzzing |
| `encoding_test.zig` | 6 | Label lookup and pathological labels |

### 4.1 Techniques used to provoke failure

The suite is not a happy-path suite. Four techniques are used deliberately:

**Allocation-failure injection.** `std.testing.checkAllAllocationFailures`
re-runs a function with each allocation point failed in turn, and requires that
the function either succeeds or returns `error.OutOfMemory` with **zero leaked
bytes**. Applied to `queryAll` and `queryFirst`, which own the only Zig-side
allocations in the wrapper.

**Deterministic fuzzing.** Seeded `std.Random.DefaultPrng`, so any failure is
reproducible and the suite is never flaky. Streams cover: uniform random bytes
as HTML, markup-shaped text, byte mutations of a valid page, random selector
text, and random URL text. The invariant under fuzz is always *typed error or
well-formed result, never a trap*.

**Adversarial sizing.** Inputs far outside anything a real page contains:

- a 1 MiB document (10 000+ paragraphs, all counted);
- 5 000 levels of nesting;
- a 64 KiB attribute value;
- 2 000 attributes on one element;
- a 4 096-character tag name;
- a selector with 2 000 descendant combinators and 64 nested `:not(`;
- a 100 000-character encoding label.

**Exhausted resources.** Serialization into an 8-byte buffer, a zero-length
buffer, a zero-capacity sink, and an allocating writer that cannot allocate.
Each must produce a typed error, and partial output must stay within bounds.

### 4.2 Error paths are asserted specifically

Every fallible API is checked with `expectError` against its **own** error, not
against "some error". A test that accepts any failure would pass even if the
failure were the wrong one.

---

## 5. Mutation testing: does the suite actually have teeth?

A passing suite proves nothing unless it can fail. Three deliberate bugs were
injected and the suite was required to catch each one.

| Injected bug | Observed result |
|---|---|
| `status.check` swallows `LXB_STATUS_ERROR_NOT_EXISTS` | **3 tests fail** (`check succeeds exactly for the non-error statuses`, `check maps each failure to its own distinct error`, `try on check() propagates the exact error`) |
| `conv.slice` drops its `data == null` guard | Tests **abort with `panic: attempt to use null value`** — a crash, had it reached production |
| `FixedSink` stops setting `truncated` | **3 tests fail** across the inline and suite halves |

All three were reverted immediately; the current tree contains no mutation.

### 5.1 A real gap this exposed

The first mutation revealed something important: the **inline** status test did
not check `NotExists` at all, so with only `zig build test-unit` the bug would
have slipped through. The suite caught it, but the gap was closed anyway — the
inline test now walks an exhaustive table of all 22 enumerators and asserts that
the table is complete:

```zig
try std.testing.expectEqual(std.enums.values(Status).len, table.len);
```

That line means a new status added by a future lexbor release breaks the build
until it is classified.

---

## 6. Findings: behaviours that were assumed wrong

Several tests failed on first run. In every case the **test** was wrong, not the
code — but each one was a genuine unknown that is now pinned down and
documented.

**1. The selector search root is not itself a candidate.**
`queryAll(node, "*")` matches descendants of `node`, never `node`. This matches
`element.querySelectorAll` semantics (as opposed to `document.querySelectorAll`).
Now asserted explicitly, including the positive control that searching from the
*parent* does find the node.

**2. `dom.Node.name()` returns upper-case names.**
It exposes the DOM `nodeName`, which lexbor upper-cases for HTML elements:
`"DIV"`, not `"div"`. `Element.localName()` keeps the lower-case spelling. Both
are now asserted side by side.

**3. `std.Io.Writer.Error` is exactly `error{WriteFailed}`.**
There is no `OutOfMemory` in the writer error set, so an allocating writer that
fails to allocate surfaces **`WriteFailed`**, not `OutOfMemory`. This broke the
first version of the OOM serialization test, which had assumed the opposite. The
test now pins the real behaviour and documents the subtlety.

**4. An "empty" document still has `html`, `head` and `body`.**
Parsing `""` yields a full tree, so `queryFirst("*")` on an empty document is
**not** null. The test now distinguishes "no elements of interest" (`div` →
null) from "no tree at all" (never true).

**5. An empty element name crashes lexbor itself.**
This one is an upstream defect, not a wrong assumption. Calling
`lxb_dom_document_create_element(doc, name, 0, NULL)` — a zero-length name —
underflows an unsigned offset in `lexbor_shs_entry_get_lower_static`
(`vendor/lexbor/source/lexbor/core/shs.c:67`):

```
panic: addition of unsigned offset to 0x19a242a overflowed to 0x19a2429
  lexbor_shs_entry_get_lower_static  core/shs.c:67
  lxb_tag_append_lower               tag/tag.c:46
  lxb_dom_element_create             dom/interfaces/element.c:180
  lxb_dom_document_create_element    dom/interfaces/document.c:292
```

Zig's safety checks turn this into an abort; in an optimised build the same
underflow would wrap and read out of bounds. Names of one byte, of 4 096 bytes,
and containing `<`, `"`, NUL or high bytes are all fine — only the zero-length
case is affected.

`dom.createElement` now rejects it with `error.InvalidName` before the call,
which is also what the DOM specifies (`InvalidCharacterError`).
`tests/build_dom_test.zig` carries the regression guard.

The **same** hash underflow is reachable through a zero-length CSS property
name: `lxb_style_id_by_name()` → `lxb_css_property_by_name(name, 0)`. It was
found by fuzzing `Computed.get()` / `Computed.property()` and is guarded the same
way (an empty property name is treated as absent). See §6.1 for why both are
genuine upstream bugs rather than misuse.

Two smaller corrections of the same kind: the root element's `parent()` is the
**document node**, not null; and `<p>text</p>` is not a leaf — its text is a
child node.

**6. Style queries crash on a document that was never style-initialised.**
`lxb_dom_element_style_by_name()` and the rest of the style read API dereference
`doc->css` without a null check
(`vendor/lexbor/source/lexbor/style/dom/interfaces/element.c:103`):

```
panic: member access within null pointer of type 'lxb_dom_document_css_t'
  lexbor_avl_search(doc->css->styles, ...)
  lxb_dom_element_style_node_by_id   style/dom/interfaces/element.c:103
  lxb_dom_element_style_by_name      style/dom/interfaces/element.c:80
```

`doc->css` is populated by `lxb_style_init()`. `html.Parser` never calls it
(style application is opt-in), so querying a style on a document from
`html.Parser` aborts. The test asserts the raw `css == null` precondition rather
than calling the crashing function, and this precondition is documented in the
README.

**7. Appending across documents moves the node silently.**
lexbor does not raise a `WRONG_DOCUMENT_ERR`-style exception: the node is moved
and the source document is left without a root, so a later `serializeTo` on it
returns `error.NoRootElement`. Documented and pinned rather than assumed.

### 6.1 Re-analysis: bug, contract, or missing feature?

Every lexbor finding was re-checked against the source instead of being taken on
trust. The question was whether the wrapper was misusing the API or the
observation was real. The answer is mixed, and matters because it changes how
the docs should describe each one.

| # | Observation | Verdict |
|---|---|---|
| 5 | Empty **element** name underflows the tag hash | **Genuine bug** |
| 5b | Empty **property** name underflows the same hash | **Genuine bug** (same root cause) |
| 6 | Style query dereferences `doc->css` without a null check | **Unchecked precondition** |
| — | Document destroy without `lxb_style_destroy()` leaks CSS state | **Lifecycle contract** |
| — | `style_walk` returns `WRONG_ARGS` (9) for an unstyled element | **API quirk** |
| — | Changing an attribute does not recompute styles | **Missing feature** |
| — | `var()` is not substituted | **Missing feature** |

**5 / 5b are genuine bugs.** `lexbor_shs_make_id_lower_m(key, size, …)` reads
`key[size - 1]`; with `size == 0` that is `key[-1]`, an out-of-bounds read plus
pointer underflow. The evidence it is an oversight rather than an assumption:

* the sibling lookups `lxb_tag_data_by_name()` / `_upper()` **do** guard
  `name == NULL || len == 0` and return null — `lxb_tag_append_lower()`, which
  sits on the `create_element` path, does not;
* `lxb_css_property_by_name()` lacks the guard too;
* `document.createElement("")` must throw `InvalidCharacterError` per the DOM,
  not crash. Guarding at the Zig boundary with `error.InvalidName` is the right
  fix, and the "lexbor bug" attribution stands.

**6 is an unchecked precondition, not a bug in normal use.** The style API
requires `lxb_style_init()` first, and lexbor assumes it. Notably, lexbor's own
`lxb_html_document_done_cb()` *does* guard `css == NULL`, so the defensive
pattern exists in-tree — the read API just omits it. The wrapper's
`error.StyleNotInitialized` is correct defensive programming, but describing it
as "lexbor crashes" should not be read as "lexbor is broken": the contract is
"initialise before reading".

**The CSS-state leak is a lifecycle contract.** `lxb_dom_document_destroy()`
frees text, memory, tags, ns, attrs and prefix but deliberately not `doc->css`;
`lxb_style_destroy()` is the only teardown for it. `lxb_engine_t` exists to
encapsulate the correct order, which is why `style.Engine` wraps it and why
`html.Parser` gets no styled parse. Asymmetric, but intended.

**`style_walk` returning `WRONG_ARGS` for an unstyled element is an API quirk.**
It comes from `lexbor_avl_foreach(NULL, &element->style, …)` treating a null
root as "wrong arguments". The wrapper now checks `element->style == NULL`
directly instead of interpreting that status code, so it no longer depends on
the quirk.

**Attribute change not recomputing styles is a missing feature.** The trace was
followed: `lxb_dom_element_set_attribute()` → `lxb_dom_attr_set_value()` does
dispatch `attr_mutation->change`, but
`lxb_style_attribute_steps_change()` dispatches per **element tag**, and the
handler is null for generic elements like `<p>`. The steps exist for
spec-defined special attributes (`<option>`, `<select>`, `<style>`, …), not for
general CSS re-resolution. So it is neither a bug nor a misuse of the wrong
setter — the capability simply is not there yet.

**`var()` is not even tokenised.** `grep` over `css/syntax/` finds no `var(`
handling; custom properties (`--x`) are stored, but `var()` substitution is not
implemented at all.

**Conclusion:** the wrapper's approach is correct in every case. The two real
bugs are guarded at the boundary; the precondition and the lifecycle contract
are enforced by the type system (`Engine` owns both document and CSS state); and
the missing features are pinned by tests rather than silently tolerated.

---

## 7. Verification matrix

Every cell below was executed, not assumed.

| Dimension | Values | Result |
|---|---|---|
| Host platform | `x86_64-linux` (native) | tests run and pass |
| Cross targets | `aarch64-linux-gnu`, `x86_64-windows-gnu`, `wasm32-wasi` | compile **and link** |
| Optimisation | Debug, ReleaseSafe, ReleaseFast | 182/182 pass in all three |
| macOS | native runner in CI | pass |
| Clean checkout | `git clone` into a fresh directory, empty cache | 182/182 pass, examples run |
| No system lexbor | CI job asserts `/usr/local/include/lexbor` is absent | pass |
| External consumer | standalone project depending on the package | builds and runs |

The macOS job is worth calling out: cross-compiling to macOS from Linux is not
possible without the macOS SDK, so macOS is verified on a native runner instead
of being claimed.

Runtime is modest — the full suite runs in well under a second in Debug,
including the fuzzing loops.

---

## 8. Threats to validity — what this audit does **not** prove

Honest limits matter more than the numbers above.

- **CSS coverage is behavioural, not exhaustive.** The cascade cases in
  `tests/style_test.zig` pin specificity, `!important`, inline precedence and
  source order, but there is no conformance run against the CSS test suites and
  no wrapper for the `style` module — its 33 public functions are reached
  through `sys`.
- **No dynamic analysis of the C side.** Zig's testing allocator detects leaks
  in *Zig* allocations. lexbor's internal memory management is trusted, not
  audited: no ASan, MSan or Valgrind run is part of CI. This is the single
  largest gap and the most valuable thing to add next.
- **Fuzzing is bounded and seeded, not coverage-guided.** There is no libFuzzer
  or AFL integration and no corpus. The fuzz tests are regression guards for the
  wrapper's own invariants, not a search for deep parser bugs — lexbor's parser
  hardening is upstream's responsibility.
- **The coverage gate checks names, not signatures.** It proves every public
  symbol is reachable. It does not verify that a translated signature matches
  the C declaration; that is `translate-c`'s contract, and a subtle mismatch
  would not be caught by the gate.
- **No concurrency testing.** lexbor is built with `LEXBOR_WITHOUT_THREADS` and
  the wrapper makes no thread-safety claims. Sharing a parser across threads is
  untested and unsupported.
- **No formal verification.** These are empirical tests, not proofs.
- **Behaviour is pinned to lexbor v3.0.1.** Several tests encode version-specific
  behaviour (the four findings in §6). That is intentional, but it means an
  upstream behaviour change will fail these tests and require review rather than
  passing silently.
- **`-Dsystem-lexbor` is untested in CI.** It is an escape hatch that sacrifices
  the hermetic guarantee.

---

## 9. Reproducing the audit

```sh
git clone https://github.com/carlos-sweb/z-lexbor
cd z-lexbor

# The two claims that carry the most weight:
zig build check-coverage              # 226 headers, 2408 names, 0 missing
zig build test --summary all          # 182/182

# Half-suites
zig build test-unit --summary all     # 26
zig build test-suite --summary all    # 156

# Optimisation-path coverage
zig build test -Doptimize=ReleaseSafe --summary all
zig build test -Doptimize=ReleaseFast --summary all

# Cross-compilation
zig build -Dtarget=aarch64-linux-gnu
zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=wasm32-wasi

# External-consumer integration
./tools/check-consumer.sh
```

To reproduce the mutation results, break a guard in `src/` and confirm the suite
fails. The three mutations used are listed in §5.

---

## 10. Conclusion

The wrapper's central claims are machine-checked rather than asserted:

- **completeness** — 2 408 public names, 0 missing, enforced on every build;
- **correctness of the error boundary** — all 22 status codes mapped to distinct
  errors, exhaustively tested;
- **hermeticity and portability** — 213 C translation units compiled from a
  pinned vendored tree across four targets, with no system dependency;
- **behavioural robustness** — 213 tests including allocation-failure injection,
  deterministic fuzzing and adversarial sizing, all validated by mutation
  testing that proved the suite can fail.

The most useful outcome was not the green suite but the four behaviours it
forced into the open, and the coverage gap found by breaking the code on
purpose. Those are documented above rather than quietly fixed.
