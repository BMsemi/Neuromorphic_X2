param([string]$VivadoBin = 'C:\Vivado\2022.2\bin')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root 'build\axi_simulation'
New-Item -ItemType Directory -Force -Path $build | Out-Null
Push-Location $build
try {
 & (Join-Path $VivadoBin 'xvlog.bat') --sv ../../rtl/shared_fifo32.v ../../rtl/pe512_core.v ../../rtl/l2_accumulator.v ../../rtl/pe512_system.v ../../rtl/pe512_axi.v ../../sim/tb_pe512_axi.sv
 if ($LASTEXITCODE -ne 0) { throw 'Compilation failed' }
 & (Join-Path $VivadoBin 'xelab.bat') work.tb_pe512_axi -s shared_pe_axi_tb -debug typical
 if ($LASTEXITCODE -ne 0) { throw 'Elaboration failed' }
 & (Join-Path $VivadoBin 'xsim.bat') shared_pe_axi_tb -tclbatch ../../scripts/simulate.tcl -log simulation.log
 if (!(Select-String -LiteralPath simulation.log -SimpleMatch 'ALL_AXI_SHARED_PE_TESTS_PASSED' -Quiet)) { throw 'AXI simulation failed' }
} finally { Pop-Location }
