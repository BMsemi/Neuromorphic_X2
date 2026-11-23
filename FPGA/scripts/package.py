"""Package only the new shared-FIFO RTL and the final validation evidence."""
from pathlib import Path
import hashlib
import json
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    simulation = (ROOT / "build/simulation/simulation.log").read_text()
    synthesis = (ROOT / "build/synthesis/vivado.log").read_text()
    assert "ALL_SHARED_PE_TESTS_PASSED" in simulation and "Fatal:" not in simulation
    assert "SHARED_PE_SYNTHESIS_PASSED" in synthesis
    assert "Synthesis finished with 0 errors, 0 critical warnings" in synthesis
    physical_dir = ROOT / 'build/physical'
    physical = json.loads((physical_dir/'physical_validation.json').read_text())
    mnist = json.loads((physical_dir/'mnist_validation.json').read_text())
    assert physical['status'] == 'PASS' and mnist['status'] == 'PASS'
    assert 'ALL_AXI_SHARED_PE_TESTS_PASSED' in (ROOT/'build/axi_simulation/simulation.log').read_text()
    assert 'SHARED_PE_BITSTREAM_PASSED' in (physical_dir/'build.log').read_text()
    assert 'End of startup status: HIGH' in (physical_dir/'program.log').read_text()
    assert physical['magic'] == '0x53503531' and physical['version'] == '0x10000'
    manifest = json.loads((physical_dir/'board_manifest.json').read_text())
    assert manifest['bitstream_sha256'] == hashlib.sha256((physical_dir/'overlay/shared_pe.bit').read_bytes()).hexdigest()
    assert manifest['rtl_hashes'] == json.loads((physical_dir/'rtl_build_hashes.json').read_text())
    for name, digest in manifest['rtl_hashes'].items():
        assert hashlib.sha256((ROOT/'rtl'/name).read_bytes()).hexdigest() == digest
    for name, digest in manifest['files'].items():
        assert hashlib.sha256((ROOT/'scripts'/name).read_bytes()).hexdigest() == digest
    files = {}
    for folder, pattern in (("rtl", "*.v"), ("sim", "*.sv"), ("scripts", "*")):
        for path in sorted((ROOT / folder).glob(pattern)):
            if path.is_file():
                files[path.relative_to(ROOT).as_posix()] = path.read_bytes()
    files["README.md"] = (ROOT / "README.md").read_bytes()
    transport = ROOT.parent/'fpga_validation/serial_console.py'
    if not transport.exists():
        transport = ROOT/'scripts/serial_console.py'
    files['scripts/serial_console.py'] = transport.read_bytes()
    for path in sorted(physical_dir.rglob('*')):
        if path.is_file() and path.suffix in ('.json', '.npz', '.rpt', '.bit', '.hwh', '.txt', '.log') and '.failure.' not in path.name and '.backup.' not in path.name:
            target = 'reports/physical/'+path.relative_to(physical_dir).as_posix()
            files[target] = path.read_bytes()
    files['reports/axi_simulation.log'] = (ROOT/'build/axi_simulation/simulation.log').read_bytes()
    baseline = ROOT.parent/'artifacts/binary_mnist/zcu106_validation_20261120/validation_inputs.npz'
    if not baseline.exists():
        baseline = ROOT/'validation_inputs.npz'
    assert hashlib.sha256(baseline.read_bytes()).hexdigest() == mnist['input_sha256']
    files['validation_inputs.npz'] = baseline.read_bytes()
    for source, target in (
        ("build/simulation/simulation.log", "reports/simulation.log"),
        ("build/synthesis/vivado.log", "reports/synthesis.log"),
        ("build/synthesis/utilization.rpt", "reports/utilization.rpt"),
        ("build/synthesis/timing_estimate.rpt", "reports/timing_estimate.rpt"),
    ):
        files[target] = (ROOT / source).read_bytes()
    validation = {
        "date": "2026-11-23", "top": "shared_pe_wrapper", "pe_top": "pe512_axi",
        "target": "xczu7ev-ffvc1156-2-e", "tool": "Vivado / XSim 2022.2",
        "logical_shape": [512, 512], "tile_shape": [32, 32], "tiles": 256,
        "shared_command_fifos": 1, "shared_response_fifos": 1,
        "fifo_depth_words": 32, "fifo_word_bits": 32,
        "rtl_simulation": "pass", "out_of_context_synthesis": "pass",
        "full_sweep_responses_checked": 8192, "l2_columns_checked": 512,
        "luts": 1666, "flip_flops": 463, "ramb36": 7, "ramb18": 1, "dsps": 0,
        "resource_scope": "above utilization is core out-of-context; full routed utilization in physical overlay report",
        "ps_compute_fallback": False, "placed_and_routed": True,
        "new_rtl_programmed_on_board": True, "new_rtl_physical_validation": True,
        "ps_bus_wrapper": "AXI-Lite at 0xA0000000; pe512_axi",
        "physical_validation": physical, "mnist_validation": mnist,
        "files": {name: hashlib.sha256(data).hexdigest() for name, data in sorted(files.items())},
    }
    files["validation.json"] = json.dumps(validation, indent=2).encode()
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    archive = dist / "pe512_shared_fifo_fpga_validated.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in sorted(files.items()):
            z.writestr(name, data)
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        for name, digest in validation["files"].items():
            assert hashlib.sha256(z.read(name)).hexdigest() == digest
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(digest + "  " + archive.name + "\n")
    print(json.dumps({"archive": str(archive), "bytes": archive.stat().st_size,
                      "sha256": digest, "files": len(files)}, indent=2))


if __name__ == "__main__":
    main()
