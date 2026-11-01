"""Cocotb tests for runner."""

import argparse
import json
import os
import sys
from pathlib import Path

# cocotb 2.0 split the Python test-runner API out of the main cocotb
# package into cocotb-tools, imported as cocotb_tools.runner — this
# repo's requirements.txt pulls unpinned cocotb, which now resolves to
# 2.x, so the old `cocotb.runner` import 404s. See insper-riscv/Tools'
# own sim_runner module for the same migration.
from cocotb_tools.runner import get_results, get_runner


def _resolve_parameter(value, repo_root: Path) -> str:
    """Return a generic of the design as the simulator expects it.

    Booleans become VHDL literals, integers become decimal text, and a
    path is made absolute, from the current directory or, failing that,
    from the repository root. Anything else is kept as it is.
    """
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    for candidate in (Path(value), repo_root / value):
        if candidate.exists():
            return str(candidate.resolve())
    return str(value)


def _build_dir(tests_root: Path, test_module: str, toplevel: str) -> Path:
    """Return the build directory of a test, one per group of tests."""
    if ".entities." in test_module:
        group = "entities"
    elif ".instructions." in test_module:
        group = "instructions"
    else:
        group = "misc"

    name = (
        test_module.rsplit(".", maxsplit=1)[-1]
        if group == "instructions"
        else toplevel
    )
    return tests_root / "python/sim_build" / group / name


def run_cocotb_test(  # noqa: PLR0913, PLR0917
    toplevel: str,
    sources: list,
    test_module: str,
    parameters: dict | None = None,
    build_args: list | None = None,
    test_args: list | None = None,
):
    """Build the design and run one cocotb test module."""
    tests_root = Path(__file__).resolve().parents[1]
    repo_root = Path(__file__).resolve().parents[2]
    sys.path.append(str(repo_root))

    sim = os.getenv("SIM", "ghdl")
    vhdl_sources = [repo_root / src for src in sources]

    runner = get_runner(sim)

    build_dir = _build_dir(tests_root, test_module, toplevel)
    build_dir.mkdir(parents=True, exist_ok=True)

    parameters = {
        k: _resolve_parameter(v, repo_root)
        for k, v in (parameters or {}).items()
    }

    runner.build(
        vhdl_sources=vhdl_sources,
        hdl_toplevel=toplevel,
        always=True,
        build_dir=build_dir,
        parameters=parameters or {},
        build_args=build_args or [],
    )

    wave_file = build_dir / "waves.ghw"
    plusargs = [f"--wave={wave_file}"]

    results_xml = runner.test(
        hdl_toplevel=toplevel,
        hdl_toplevel_lang="vhdl",
        test_module=test_module,
        build_dir=build_dir,
        plusargs=plusargs,
        test_args=test_args or [],
    )

    print(f"Waves: {wave_file} (gerado)")

    # runner.test() returns normally when a cocotb test fails; the
    # failures are only in results.xml
    total, failed = get_results(results_xml)
    if failed:
        raise RuntimeError(f"{failed} of {total} cocotb tests failed")


if __name__ == "__main__":
    tests_root = Path(__file__).resolve().parents[1]
    json_path = tests_root / "python/tests.json"

    try:
        with json_path.open() as f:
            TEST_CONFIGS = json.load(f)
    except FileNotFoundError:
        print(f"Erro: Arquivo de configuração '{json_path}' não encontrado.")
        sys.exit(1)
    except json.JSONDecodeError:
        print(f"Erro: O arquivo JSON '{json_path}' está mal formatado.")
        sys.exit(1)

    parser = argparse.ArgumentParser(
        description="Runner de Testes Cocotb para o projeto RV32I"
    )
    parser.add_argument(
        "test_name",
        nargs="?",
        default="all",
        help=(
            f"Nome do teste a ser executado. Opções: {[*TEST_CONFIGS, 'all']}"
        ),
    )
    args = parser.parse_args()

    if args.test_name == "all":
        print("Executando TODOS os testes definidos em tests.json...")
        failures = []
        for name, config in TEST_CONFIGS.items():
            # "skip"/"skip_reason": a config-level opt-out (not a
            # removal) for a test that's currently known-broken for a
            # reason unrelated to whatever change is being tested right
            # now -- same spirit as the asm/c suite's own .off files,
            # adapted to this suite's single tests.json instead of one
            # file per test. Only skipped in the "all" sweep; running
            # it by name explicitly (`runner.py <name>`) still attempts
            # it, e.g. to check whether a fix actually resolved it.
            if config.get("skip"):
                reason = config.get("skip_reason", "no reason given")
                print(f"\n{'=' * 20} PULANDO TESTE: {name.upper()} {'=' * 20}")
                print(f"[SKIP] {reason}")
                continue
            print(f"\n{'=' * 20} INICIANDO TESTE: {name.upper()} {'=' * 20}")
            try:
                run_cocotb_test(
                    **{
                        k: v
                        for k, v in config.items()
                        if k not in ("skip", "skip_reason")
                    }
                )
                print(
                    f"{'-' * 20} TESTE {name.upper()} FINALIZADO COM SUCESSO "
                    f"{'-' * 20}"
                )
            except Exception as e:  # noqa: BLE001
                failures.append(name)
                print(f"[ERRO] O teste '{name}' falhou: {e}")
        print("\nTodos os testes foram executados.")
        if failures:
            print(
                f"[ERRO] {len(failures)} teste(s) falharam: "
                f"{', '.join(failures)}"
            )
            sys.exit(1)
    elif args.test_name in TEST_CONFIGS:
        print(f"Executando teste específico: {args.test_name}")
        config = TEST_CONFIGS[args.test_name]
        if config.get("skip"):
            print(
                f"[AVISO] '{args.test_name}' está marcado como skip "
                f"({config.get('skip_reason', 'no reason given')}) -- "
                "rodando mesmo assim, por ter sido pedido explicitamente."
            )
        run_cocotb_test(
            **{
                k: v
                for k, v in config.items()
                if k not in ("skip", "skip_reason")
            }
        )
        print(f"\nTeste {args.test_name} finalizado.")
    else:
        print(f"Erro: Teste '{args.test_name}' não encontrado em tests.json.")
        print(f"Opções disponíveis: {[*list(TEST_CONFIGS.keys()), 'all']}")
        sys.exit(1)
