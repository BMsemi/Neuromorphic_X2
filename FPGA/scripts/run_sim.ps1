param([string]$VivadoBin = 'C:\Vivado\2022.2\bin')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root 'build\simulation'
New-Item -ItemType Directory -Force -Path $build | Out-Null
Push-Location $build
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv ../../rtl/shared_fifo32.v ../../rtl/pe512_core.v ../../rtl/l2_accumulator.v ../../rtl/pe512_system.v ../../sim/tb_pe512_system.sv
    if ($LASTEXITCODE -ne 0) { throw 'RTL compilation failed' }
    & (Join-Path $VivadoBin 'xelab.bat') work.tb_pe512_system -s shared_pe_tb -debug typical
    if ($LASTEXITCODE -ne 0) { throw 'RTL elaboration failed' }
    & (Join-Path $VivadoBin 'xsim.bat') shared_pe_tb -tclbatch ../../scripts/simulate.tcl -log simulation.log
    if ($LASTEXITCODE -ne 0) { throw 'RTL simulation failed' }
    if (!(Select-String -LiteralPath simulation.log -SimpleMatch 'ALL_SHARED_PE_TESTS_PASSED' -Quiet)) {
        throw 'Simulation did not reach its required pass marker'
    }
} finally { Pop-Location }
