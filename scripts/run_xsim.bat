@echo off
rem =====================================================================
rem  run_xsim.bat - run all three testbenches with Vivado's simulator
rem                (XSim), no project needed. Windows.
rem
rem  Open "Vivado 20xx.x Tcl Shell" from the Start menu (or a cmd window
rem  after running  <Vivado install>\settings64.bat), then:
rem       cd <package folder>
rem       scripts\run_xsim.bat
rem  Transcripts go to logs\run.log, logs\run_sar.log, logs\run_temp.log
rem =====================================================================
setlocal
cd /d "%~dp0.."
if not exist logs mkdir logs
if not exist xsim_work mkdir xsim_work
cd xsim_work

call xvlog ..\rtl\ddq_apuf.v ..\rtl\ddq_sar.v ..\tb\tb_ddq_apuf.v ..\tb\tb_ddq_sar.v ..\tb\tb_ddq_temp.v
if errorlevel 1 goto fail

call xelab -s snap_apuf tb_ddq_apuf
if errorlevel 1 goto fail
call xsim snap_apuf -R -log ..\logs\run.log
if errorlevel 1 goto fail

call xelab -s snap_sar tb_ddq_sar
if errorlevel 1 goto fail
call xsim snap_sar -R -log ..\logs\run_sar.log
if errorlevel 1 goto fail

call xelab -s snap_temp tb_ddq_temp
if errorlevel 1 goto fail
call xsim snap_temp -R -log ..\logs\run_temp.log
if errorlevel 1 goto fail

cd ..
findstr /C:"TEST PASSED" /C:"TEST FAILED" logs\run.log logs\run_sar.log logs\run_temp.log
echo.
echo Plot with:  python plot_ddq.py logs\run.log logs\run_sar.log logs\run_temp.log
exit /b 0

:fail
echo *** XSim step failed - see the messages above ***
exit /b 1
