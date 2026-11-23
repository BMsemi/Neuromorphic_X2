"""Upload and run physical tests via COM17. Program the bitstream separately first.

Use --prepare to upload without executing. Uses the prior frozen 100-image NPZ
already on this board; override --inputs to select another compatible file.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT.parent / 'fpga_validation'))
from serial_console import Console


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--port', default='COM17')
    parser.add_argument('--remote', default='/home/xilinx/shared_pe_validation_20261123')
    parser.add_argument('--inputs', default='/home/xilinx/qwen6_20261005/mnist_validation_ee44545bba75/validation_inputs.npz')
    args = parser.parse_args()
    out = ROOT / 'build/physical'
    out.mkdir(parents=True, exist_ok=True)
    manifest = {'remote_directory': args.remote, 'port': args.port, 'files': {}}
    bit = out/'overlay/shared_pe.bit'
    if not bit.exists():
        bit = ROOT/'reports/physical/overlay/shared_pe.bit'
    if bit.exists():
        manifest['bitstream_sha256'] = hashlib.sha256(bit.read_bytes()).hexdigest()
    manifest['rtl_hashes'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in sorted((ROOT/'rtl').glob('*.v'))}
    with Console(args.port) as console:
        console.command('mkdir -p ' + shlex.quote(args.remote))
        for name in ('board_validate.py', 'board_mnist.py'):
            data = (ROOT/'scripts'/name).read_bytes()
            digest = hashlib.sha256(data).hexdigest()
            console.upload(data, args.remote+'/'+name)
            assert digest in console.command('sha256sum '+shlex.quote(args.remote+'/'+name))
            manifest['files'][name] = digest
            print('Uploaded and verified '+name, flush=True)
        manifest['input_checksum'] = console.command('sha256sum '+shlex.quote(args.inputs)).strip()
        (out/'board_manifest.json').write_text(json.dumps(manifest, indent=2))
        if args.prepare:
            return
        for script, argument, marker, outputs in (
            ('board_validate.py', '', 'PHYSICAL_SHARED_PE_TESTS_PASSED', ['physical_validation.json', 'physical_vectors.json']),
            ('board_mnist.py', ' '+shlex.quote(args.inputs), 'PHYSICAL_SHARED_PE_MNIST_PASSED', ['mnist_validation.json', 'mnist_outputs.npz']),
        ):
            cmd = 'cd '+shlex.quote(args.remote)+' && sudo -n /usr/local/share/pynq-venv/bin/python3 -u '+script+argument
            try:
                log = console.command(cmd, timeout=600, on_output=lambda s: print(s, end='', flush=True))
            except Exception as exc:
                (out/(script+'.failure.log')).write_text(str(exc))
                raise
            (out/(script+'.log')).write_text(log)
            assert marker in log
            for name in outputs:
                data = console.download(args.remote+'/'+name, timeout=60)
                assert hashlib.sha256(data).hexdigest() in console.command('sha256sum '+shlex.quote(args.remote+'/'+name))
                (out/name).write_bytes(data)
                print('Retrieved and verified '+name, flush=True)


if __name__ == '__main__':
    main()
