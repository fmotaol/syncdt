@echo off
setlocal enabledelayedexpansion

echo ==========================================
echo Iniciando processo de fetch e pull...
echo ==========================================

git fetch --all

echo.
echo Branches disponiveis:
git branch -a
echo.

set /p branch="Digite a branch para pull (enter para main): "

if "%branch%"=="" set branch=main

echo.
echo Realizando pull da branch %branch%

git pull origin %branch%

echo.
echo ==========================================
echo Fetch/Pull concluido!
pause
goto :eof