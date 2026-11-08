# Contribution Guide

🌐 [Português](CONTRIBUTING.md) · [English](CONTRIBUTING.en.md)

This document defines the mandatory coding (VHDL, C, and Python), structural organization, documentation, and verification rules for any contribution to the `Memory` repository.

## 1. VHDL-2008 Standard and Synthesis Compatibility

All hardware code in the project is written and validated under the **IEEE 1076-2008 (VHDL-2008)** standard, compiled in GHDL with the `--std=08` flag, and synthesized in Quartus Prime.

| Rule | Specification |
| :--- | :--- |
| Language standard | VHDL-2008 (`--std=08`) across all `.vhd` files |
| Permitted IEEE packages | Only `ieee.std_logic_1164.all` and `ieee.numeric_std.all` |
| Prohibited packages | `std_logic_arith`, `std_logic_unsigned`, and `std_logic_signed` must never be used |
| Module instantiation | Use direct entity instantiation (`u_name : entity work.entity_name`), without redundant `component` declarations |
| Port mapping (`port map`) | Always associate by name (`i_port => signal`) and use intermediate signals for logical expressions or dynamic slices, because GHDL requires globally static expressions in port map actuals |
| Latch prevention | Every signal assigned in a combinational process or conditional assignment must receive an explicit default value across all branches (`else` / `when others =>`) |

The reference standard is [IEEE Std 1076-2008, IEEE Standard VHDL Language Reference Manual](https://standards.ieee.org/ieee/1076/3666/). In academic work, cite it with the BibTeX entry below:

```bibtex
@misc{ieee1076,
  title        = {IEEE Standard VHDL Language Reference Manual},
  author       = {{IEEE}},
  year         = {2008},
  note         = {IEEE Std 1076-2008},
  howpublished = {\url{https://standards.ieee.org/ieee/1076/3666/}}
}
```

The organization into reusable blocks with explicit interfaces and parameters follows [IEEE Std 1685, IEEE Standard for IP-XACT](https://standards.ieee.org/ieee/1685/10583/), whose BibTeX entry is:

```bibtex
@misc{ieee1685,
  title        = {IEEE Standard for IP-XACT, Standard Structure for Packaging, Integrating, and Reusing IP within Tool Flows},
  author       = {{IEEE}},
  year         = {2022},
  note         = {IEEE Std 1685-2022},
  howpublished = {\url{https://standards.ieee.org/ieee/1685/10583/}}
}
```

The design-for-reuse methodology for hardware blocks follows the book *Reuse Methodology Manual for System-on-a-Chip Designs* (3rd edition, Springer, 2002) by Keating and Bricaud, a copyrighted work available only by purchase or through an institutional library:

```bibtex
@book{keating2002rmm,
  title     = {Reuse Methodology Manual for System-on-a-Chip Designs},
  author    = {Keating, Michael and Bricaud, Pierre},
  edition   = {3},
  year      = {2002},
  publisher = {Springer},
  isbn      = {978-1402071416}
}
```

## 2. C Standard and Test Programs

All C code in the project, wherever it lives (test programs, runtime, and platform startup code), is written under the **ISO/IEC 9899:2024 (C23)** standard and compiled with the `-std=c23` flag. C is the language of the programs that exercise the processor, and it is through them that the hardware modules are verified in simulation and on the board.

| Rule | Specification |
| :--- | :--- |
| Language standard | C23 (`-std=c23`) across all `.c` and `.h` files |
| Compiler extensions | Do not use GNU extensions when the standard has an equivalent |
| Standard library | picolibc, as provided by the Infra toolchain image |

The reference standard is [ISO/IEC 9899:2024, Programming languages: C](https://www.iso.org/standard/82075.html). In academic work, cite it with the BibTeX entry below:

```bibtex
@misc{iso9899,
  title        = {Programming languages --- C},
  author       = {{ISO/IEC}},
  year         = {2024},
  note         = {ISO/IEC 9899:2024},
  howpublished = {\url{https://www.iso.org/standard/82075.html}}
}
```

## 3. Mandatory VHDL Naming and Port Prefixes

All code identifiers must be written in **English**, whereas all comments and file headers must be written in **Portuguese**.

| VHDL Element | Convention | Examples |
| :--- | :--- | :--- |
| Entities, architectures, and packages | `snake_case` | `icache`, `sdram_ctrl`, `flash_arbiter`, `rtl` |
| Input ports (`in`) | Mandatory `i_` prefix + `snake_case` | `i_clk`, `i_rst`, `i_addr`, `i_invalidate` |
| Output ports (`out`) | Mandatory `o_` prefix + `snake_case` | `o_data`, `o_d_addr`, `o_d_advance` |
| Generics | Descriptive `snake_case` | `size_bits`, `tck_ps`, `init_cycles`, `refresh_cycles` |
| Constants (`constant`) | `UPPER_SNAKE_CASE` | `INDEX_BITS`, `TAG_BITS`, `C_RCD` |
| Types and subtypes (`type`, `subtype`) | `snake_case` with `_t` suffix | `state_t`, `data_t`, `tag_t` |
| Internal signals and variables | `snake_case` | `data_ram`, `tag_ram`, `valid` |
| Instance labels | `u_` prefix + `snake_case` | `u_sync_req` |
| Generate labels | `gen_` prefix + `snake_case` | `gen_has_m`, `gen_lanes` |
| Process labels | `p_` prefix + `snake_case`, mandatory on every process and repeated on `end process` | `p_regs`, `p_next_state`, `p_sync_done` |

## 4. VHDL File Headers and Docstrings

### 4.1. Mandatory File Header

Every `.vhd` file must begin with a header block (`-- ====...====`) in Portuguese describing the architectural responsibility of the package or entity. No VHDL line is longer than 120 characters (the VSG default), no file exceeds 2000 lines and no process exceeds 500:

```vhdl
-- ============================================================================
-- <Short title of the package or entity>
-- ============================================================================
-- <Clear description in Portuguese of the module's role in the processor,
--  primary interfaces, cycle/latency invariants, or parameters.>
-- ============================================================================
```

Internal sections within an architecture must use single-hyphen dividers (`-- ----...----`).

### 4.2. Individual Docstring Above Every Declaration

Every individual `generic`, `port`, `constant`, `subtype`, `type`, `signal`, `alias`, and `variable` declaration must have its own descriptive comment in Portuguese on the line immediately above it. End-of-line inline comments do not replace the docstring above the declaration:

```vhdl
entity mux_2x1 is
    generic(
        -- Largura em bits dos barramentos de entrada e saída
        data_width : natural := 32
    );
    port(
        -- Entrada selecionada quando i_sel vale '0'
        i_d0  : in  std_logic_vector(data_width - 1 downto 0);
        -- Entrada selecionada quando i_sel vale '1'
        i_d1  : in  std_logic_vector(data_width - 1 downto 0);
        -- Bit seletor entre i_d0 ('0') e i_d1 ('1')
        i_sel : in  std_logic;
        -- Saída multiplexada resultante
        o_out : out std_logic_vector(data_width - 1 downto 0)
    );
end entity mux_2x1;
```

## 5. Design for Reuse and Zero Duplication

The project follows the *Design for Reuse* practice described in the *Reuse Methodology Manual* (Keating and Bricaud). Each rule below translates into a criterion that can be checked in review:

| # | Rule | Review criterion |
| :--- | :--- | :--- |
| 1 | **Single-purpose blocks:** separate control, datapath, and protocol interface into distinct entities | An entity with more than one job must be split; a structural top level only connects instances |
| 2 | **Parameterization through `generic` and package constants:** no width, depth, or feature fixed inside the architecture | No magic literal in the logic; codes, addresses, and selectors live in constant packages |
| 3 | **Standardized, interchangeable interfaces:** entities with the same port signature can be swapped without changing whoever instantiates them | Changing a block's architecture must not change its ports or its externally observable behavior |
| 4 | **Lean ports:** the entity exposes only the ports and generics it uses | Signals or generics "for future use" do not belong in an entity |
| 5 | **Dependence on ports only:** the upper level knows the entity declaration, never the internals of its architecture | The top level never carries fine-grained implementation logic |
| 6 | **Composition with already verified leaf blocks:** reuse existing primitives | Do not reimplement with ad-hoc processes or operators what a primitive or an already computed signal provides |
| 7 | **Vendor code isolated from portable RTL:** whatever depends on a Cyclone V IP or primitive lives in `Cyclone-V/`, while RTL synthesizable on any FPGA and the simulation models live in `SoC/` | No file under `SoC/` instantiates a vendor IP or library |

## 6. Python Standards

The Python code (runner and tests under `tests/python/`) follows [PEP 8](https://peps.python.org/pep-0008) (style) and [PEP 257](https://peps.python.org/pep-0257) (docstrings); `ruff` checks both (rules `E`, `W`, `N`, and `D`).

### 6.1. Code Style (PEP 8)

> **Deviation from PEP 8.** PEP 8 asks for comments in English, and this project writes them in **Portuguese**. Every other PEP 8 recommendation on comments still applies, namely complete sentences, kept up to date, and never restating what the code already says. Identifiers stay in English.

| Rule | Specification |
| :--- | :--- |
| Indentation | 4 spaces per level; tabs prohibited |
| Encoding | UTF-8, with no encoding declaration in the file |
| Line length | At most 79 characters for code; 72 for docstrings and comments |
| Naming | `snake_case` for functions, methods, variables, and modules; `PascalCase` for classes; `UPPER_SNAKE_CASE` for constants; `_` prefix for internal names |
| Imports | At the top of the file, one per line, in three groups separated by a blank line (standard library, third party, project), each group sorted alphabetically; absolute imports only (relative imports prohibited); `import *` prohibited |
| Blank lines | Two between module-level definitions; one between methods |
| Whitespace | One space around operators and after commas; none before a call's `(`, inside brackets, or at the end of a line |
| Comparisons | `is` and `is not` for `None`; `if seq:` instead of `if len(seq):`; never `== True` or `== False` |
| Exceptions | `except` always names the specific exception; bare `except:` prohibited |
| Comments | **In Portuguese** (deviation from PEP 8); complete sentences, capitalized, on their own line or after two spaces at the end of code, starting with `# `; they explain why, not what the code does |
| Language | Identifiers in **English**; comments in **Portuguese** |

### 6.2. Docstrings (PEP 257)

| Rule | Specification |
| :--- | :--- |
| Scope | Every public module, class, function, and method has a docstring |
| Delimiter | Triple double quotes (`"""`), including one-line docstrings |
| Summary | First line on the same line as the opening quotes, in the imperative mood, ending with a period |
| One-line docstring | Closing quotes on the same line, no blank line before or after the text |
| Multi-line docstring | Summary, blank line, detailed description; closing quotes alone on the last line |
| Classes | Docstring on the class, not on `__init__`; blank line after the docstring |
| Sections | NumPy style (`Parameters`, `Returns`, `Raises`, `Examples`), with the type repeating the annotation |
| Language | Portuguese |

```python
def fetch_user(user_id: str, include_roles: bool = False) -> User:
    """Busca um usuário pelo identificador.

    Parameters
    ----------
    user_id : str
        Identificador único do usuário.
    include_roles : bool, optional
        Inclui a lista de papéis na resposta, por padrão False.

    Returns
    -------
    User
        Dados do usuário.
    """
```

### 6.3. Tooling and Process

| Rule | Specification |
| :--- | :--- |
| Package manager | `uv` (`uv add`, `uv sync`, `uv run`); `pip`, `pip install`, and `python -m pip` are prohibited |
| Tests | `pytest`; every new behavior comes with a test |
| Typing | Complete annotations, checked by Pyright and Pyrefly, both in `strict` mode |
| Style and quality | `ruff` for lint and formatting; `pylint` with a minimum score of 10; `deptry` for declared and used dependencies |
| Complexity and duplication | `complexipy` with a maximum of 10 per function; `codeclone` for duplicated code |
| Security | `semgrep` for static analysis; `uv audit` for dependency vulnerabilities |

## 7. Markdown Documentation Rules

`README`, `CONTRIBUTING`, and `AUTHORS` maintain mirrored versions in Portuguese (`*.md`) and English (`*.en.md`), and the documentation under `docs/` maintains the mirrored folders `docs/pt-br/` and `docs/en/`, following these rules:

1. **Language switcher and license footer:** every `README.md` and `README.en.md` includes the `🌐 [Português](...) · [English](...)` switcher at the top, and every `.md` file ends with the copyright footer linking to `LICENSE`.
2. **Numbered progressive sections:** all sections starting at `##` must be numbered (`## 1.`, `### 1.1.`, `## 2.`) in a logical reading order.
3. **Direct punctuation:**
   - **Em-dashes are prohibited** in prose and tables; use commas, parentheses, semicolons, or colons according to the actual syntactic relationship.
   - **Chained colons are prohibited** (more than one `:` in the same sentence or table cell).
4. **Behavior explanation:** never cite an internal file, module, or signal name as if the name itself explained what the system does; always describe the operation performed.
5. **Non-redundant tables and LaTeX:** structured data belongs in Markdown tables and mathematical/boolean equations in LaTeX blocks (`$$ ... $$` or `$ ... $`), without repeating in prose what the table or equation already states.
6. **No changelog or open TODOs in technical docs:** architecture and contract documents describe exclusively the current state, without historical bugfix notes or unimplemented work lists.
7. **Usage guides only instruct:** installation and run instructions say how to do it, without justifying the choice of method.

## 8. Mandatory Verification Before Opening a Pull Request

Any change to code, configuration, or documentation must pass the commands below without errors before submission:

```bash
make check     # Check the VHDL-2008 syntax of all sources in topological order
make test      # Run the per-entity tests (cocotb + GHDL)
make paths     # Verify the paths of paths.yaml and the repository tree (riscv-tools check-tree)
make formal    # Run the formal proofs (SymbiYosys) with the engine of FORMAL_ENGINE (bitwuzla by default)
```

The `formal` CI job runs the proofs once per engine (`formal - yices`, `formal - bitwuzla`, `formal - boolector`, and `formal - abc-bmc3`) and the aggregator job `formal` decides from the results: every proof must have an answer, and the engines that answered must agree with each other and with the expected result. The name `formal` is the check the default-branch ruleset requires, so do not rename it; the `formal - <engine>` jobs are not required. Each `formal - <engine>` job has a limit of 120 minutes in CI, because the full proofs take more than an hour on a local machine.

A warning in the formal run is an error. The formal flow scans the GHDL output and the Yosys and SymbiYosys logs after every step, including on the mutants, and fails pointing at the file and line of the warning. The fix is always in the code or in the properties, never in an option that hides the warning (`-Wno-*`). The details are in [docs/en/formal/formal.md](docs/en/formal/formal.md).

The `python-static-analysis` CI job runs `ruff`, `pycodestyle`, `pydocstyle`, `pylint`, `pyright`, `pyrefly`, `deptry`, `complexipy`, `codeclone`, `semgrep` and `uv audit` over the Python files, and the job name is the check the default-branch ruleset requires, so do not rename it.

When adding, renaming, or removing any versioned file, immediately update:
- `paths.yaml`
- `tests/python/tests.json`
- `docs/`
- `README.md`, `README.en.md`, and the affected documentation

The CI runs these checks on every push. On a pull request from someone outside the project, it starts only after a member who can merge approves the run in the pull request page.

---

Copyright 2026 Insper. Licensed under the [Apache License, Version 2.0](LICENSE).
