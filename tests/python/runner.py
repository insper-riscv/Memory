"""Cocotb tests for runner."""

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

# cocotb 2.0 split the Python test-runner API out of the main cocotb
# package into cocotb-tools, imported as cocotb_tools.runner — this
# repo's requirements.txt pulls unpinned cocotb, which now resolves to
# 2.x, so the old `cocotb.runner` import 404s. See insper-riscv/Tools'
# own sim_runner module for the same migration.
from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner


def _resolve_parameter(value: bool | int | str, repo_root: Path) -> str:
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
    sources: list[str],
    test_module: str,
    parameters: dict[str, bool | int | str] | None = None,
    build_args: list[str] | None = None,
    test_args: list[str] | None = None,
) -> None:
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


def _load_configs(json_path: Path) -> dict[str, dict[str, Any]]:
    """Read the test configurations, exiting if the file is unusable."""
    try:
        with json_path.open() as f:
            return json.load(f)
    except FileNotFoundError:
        print(f"Erro: Arquivo de configuração '{json_path}' não encontrado.")
    except json.JSONDecodeError:
        print(f"Erro: O arquivo JSON '{json_path}' está mal formatado.")
    sys.exit(1)


def _run_config(config: dict[str, Any]) -> None:
    """Run one configuration, leaving out the opt-out keys."""
    run_cocotb_test(
        **{k: v for k, v in config.items() if k not in ("skip", "skip_reason")}
    )


def _sweep_one(name: str, config: dict[str, Any]) -> bool:
    """Run one test of the "all" sweep and return True if it failed.

    "skip"/"skip_reason": a config-level opt-out (not a removal) for a
    test that's currently known-broken for a reason unrelated to
    whatever change is being tested right now -- same spirit as the
    asm/c suite's own .off files, adapted to this suite's single
    tests.json instead of one file per test. Only skipped in the "all"
    sweep; running it by name explicitly (`runner.py <name>`) still
    attempts it, e.g. to check whether a fix actually resolved it.
    """
    if config.get("skip"):
        reason = config.get("skip_reason", "no reason given")
        print(f"\n{'=' * 20} PULANDO TESTE: {name.upper()} {'=' * 20}")
        print(f"[SKIP] {reason}")
        return False
    print(f"\n{'=' * 20} INICIANDO TESTE: {name.upper()} {'=' * 20}")
    try:
        _run_config(config)
    except Exception as e:  # noqa: BLE001
        print(f"[ERRO] O teste '{name}' falhou: {e}")
        return True
    print(f"{'-' * 20} TESTE {name.upper()} FINALIZADO COM SUCESSO {'-' * 20}")
    return False


def _run_all(test_configs: dict[str, dict[str, Any]]) -> None:
    """Run every test of tests.json and exit with 1 if any failed."""
    print("Executando TODOS os testes definidos em tests.json...")
    failures = [
        name
        for name, config in test_configs.items()
        if _sweep_one(name, config)
    ]
    print("\nTodos os testes foram executados.")
    if failures:
        print(
            f"[ERRO] {len(failures)} teste(s) falharam: {', '.join(failures)}"
        )
        sys.exit(1)


def _run_named(name: str, config: dict[str, Any]) -> None:
    """Run one test asked for by name, even if it is marked as skip."""
    print(f"Executando teste específico: {name}")
    if config.get("skip"):
        print(
            f"[AVISO] '{name}' está marcado como skip "
            f"({config.get('skip_reason', 'no reason given')}) -- "
            "rodando mesmo assim, por ter sido pedido explicitamente."
        )
    _run_config(config)
    print(f"\nTeste {name} finalizado.")


def main() -> None:
    """Run the cocotb tests named in tests.json."""
    tests_root = Path(__file__).resolve().parents[1]
    test_configs = _load_configs(tests_root / "python/tests.json")

    parser = argparse.ArgumentParser(
        description="Runner de Testes Cocotb para o projeto RV32I"
    )
    parser.add_argument(
        "test_name",
        nargs="?",
        default="all",
        help=(
            f"Nome do teste a ser executado. Opções: {[*test_configs, 'all']}"
        ),
    )
    args = parser.parse_args()

    if args.test_name == "all":
        _run_all(test_configs)
    elif args.test_name in test_configs:
        _run_named(args.test_name, test_configs[args.test_name])
    else:
        print(f"Erro: Teste '{args.test_name}' não encontrado em tests.json.")
        print(f"Opções disponíveis: {[*test_configs, 'all']}")
        sys.exit(1)


if __name__ == "__main__":
    main()
